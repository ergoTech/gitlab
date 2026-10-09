#!/bin/bash
# Untag old per-commit image tags in the container registry's filesystem
# metadata. Run it ONCE, with the registry stopped, right before importing that
# metadata into the registry database (README, "Registry metadata database").
# After the import it refuses to run: the registry no longer reads these files.
#
# Why before the import: the import gives every tag it copies the time of the
# import as its creation time. GitLab's cleanup policies age tags by that time
# once the database is on, so for `older_than` (14d here) after the import they
# find nothing old enough, and `keep_n` cannot tell which imported tags are the
# newest. This script still sees the real push time and untags what the policy
# would have removed, so the policies start from a registry that is already in
# shape. The blobs only the untagged images used are imported too, as
# unreferenced, and online GC deletes them over the following days.
#
# Why the policies could not do it before: without the database GitLab ages a
# tag by the `created` field of the image config it fetches through the tag's
# manifest (`ContainerRegistry::Tag#created_at`). A multi-arch image is an OCI
# index, which has no config, so the age comes back nil and
# `partition_by_older_than` keeps the tag. backend/core's sha tags are all
# multi-arch. On 2026-10-09 it had 375 tags with the policy (keep 10, older
# than 14d) enabled since at least 2026-09-03; in the retained sidekiq logs
# (2026-10-04..09) the worker reported `deleted_size: 0`, `cleanup_status:
# unfinished` and re-queued itself about once a second.
#
# What it removes: only tags named exactly like a short commit sha
# (^[0-9a-f]{8}$, the same pattern the GitLab policies use, and what
# build/base's build-latest pushes). `latest`, `master`, version tags and any
# other named tag are never touched. Of the sha tags in a repository, the
# newest REGISTRY_TAG_KEEP_N are always kept, and so is any tag pushed within
# the last REGISTRY_TAG_RETENTION_DAYS. A tag goes only when it fails both.
#
# Age is the modification time of the tag's `current/link`, which the registry
# rewrites on every push of that tag, so a re-pushed tag counts as new.
#
# How: by deleting the tag's directory, `_manifests/tags/<tag>`. That is what
# the registry's own untag does in filesystem storage. It does not delete the
# manifest, so an image another tag still points at (`latest`, for one) is
# untouched. Run it with the registry up and the race is a push of an old
# commit's tag in the same instant — it would lose that tag, nothing else.
#
# Usage:
#   ./scripts/registry-prune-tags.sh --dry-run   # list what would go
#   ./scripts/registry-prune-tags.sh             # untag
#
# Exit code is non-zero if the storage path is wrong, the registry already uses
# its database, or any removal failed.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# The host side of the gitlab container's
# /var/opt/gitlab/gitlab-rails/shared/registry, the rootdirectory in the
# registry's config.yml.
REGISTRY_REPOS="${REGISTRY_REPOS:-$SCRIPT_DIR/../data/gitlab/data/gitlab-rails/shared/registry/docker/registry/v2/repositories}"
REGISTRY_REPOS=${REGISTRY_REPOS%/}
REGISTRY_TAG_RETENTION_DAYS="${REGISTRY_TAG_RETENTION_DAYS:-14}"
REGISTRY_TAG_KEEP_N="${REGISTRY_TAG_KEEP_N:-10}"

SHA_TAG='^[0-9a-f]{8}$'

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Whole numbers only, at most 6 digits, normalised to base ten — the same
# reasoning as BUILD_CONTAINER_RETENTION_HOURS in maintenance.sh.
whole_number() {
    local name=$1 value=$2
    case "$value" in
        ''|*[!0-9]*|???????*)
            echo "$name must be a whole number, at most 6 digits, got '$value'" >&2
            exit 2
            ;;
    esac
    echo $(( 10#$value ))
}

days=$(whole_number REGISTRY_TAG_RETENTION_DAYS "$REGISTRY_TAG_RETENTION_DAYS")
keep_n=$(whole_number REGISTRY_TAG_KEEP_N "$REGISTRY_TAG_KEEP_N")
if [ "$days" -lt 1 ]; then
    echo "REGISTRY_TAG_RETENTION_DAYS must be at least 1" >&2
    exit 2
fi

if [ ! -d "$REGISTRY_REPOS" ]; then
    echo "No registry storage at $REGISTRY_REPOS — set REGISTRY_REPOS" >&2
    exit 1
fi

# The whole repositories tree, never a part of it: the lockfile check below finds
# the lockfiles by replacing that suffix, so pointed at one repository it would
# look in the wrong place and wave the run through.
case "$REGISTRY_REPOS" in
    */docker/registry/v2/repositories) ;;
    *)
        echo "REGISTRY_REPOS must be <rootdirectory>/docker/registry/v2/repositories, got '$REGISTRY_REPOS'" >&2
        exit 2
        ;;
esac

# Written by the import, next to v2/, as soon as it has all the tags in. From then
# on the database is the registry's metadata: removing a tag here changes nothing
# it serves, and only spoils this storage as a rollback point.
if [ -e "${REGISTRY_REPOS%/v2/repositories}/lockfiles/database-in-use" ]; then
    echo "The registry uses its metadata database (lockfiles/database-in-use exists) — untag through GitLab's cleanup policies or the API instead" >&2
    exit 1
fi

cutoff=$(( $(date +%s) - days * 86400 ))
failed=0
total_untagged=0
repos=0

# A repository is any directory holding `_manifests`. Repositories nest
# (backend/core/backoffice lives inside backend/core), so this walks the whole
# tree, but never descends into the registry's own `_`-prefixed directories:
# `_layers` alone holds thousands of links per repository.
while IFS= read -r repo; do
    repos=$((repos + 1))
    name=${repo#"$REGISTRY_REPOS"/}
    tags_dir="$repo/_manifests/tags"
    [ -d "$tags_dir" ] || continue

    # "<mtime> <tag>", newest first.
    sha_tags=$(
        for t in "$tags_dir"/*; do
            tag=${t##*/}
            [[ $tag =~ $SHA_TAG ]] || continue
            [ -f "$t/current/link" ] || continue
            echo "$(stat -c %Y "$t/current/link") $tag"
        done | sort -rn
    )
    [ -n "$sha_tags" ] || continue

    count=0 untagged=0 kept=0
    while read -r mtime tag; do
        count=$((count + 1))
        if [ "$count" -le "$keep_n" ] || [ "$mtime" -ge "$cutoff" ]; then
            kept=$((kept + 1))
            continue
        fi
        if [ "$DRY_RUN" = true ]; then
            log "would untag ${name}:${tag} (pushed $(date -d "@$mtime" '+%Y-%m-%d'))"
            untagged=$((untagged + 1))
        elif rm -rf -- "${tags_dir:?}/${tag:?}"; then
            untagged=$((untagged + 1))
        else
            echo "could not untag ${name}:${tag}" >&2
            failed=1
        fi
    done <<<"$sha_tags"

    if [ "$untagged" -gt 0 ]; then
        verb=untagged; [ "$DRY_RUN" = true ] && verb="would untag"
        log "${name}: ${verb} ${untagged} sha tag(s), kept ${kept}"
    fi
    total_untagged=$((total_untagged + untagged))
done < <(find "$REGISTRY_REPOS" -mindepth 1 -type d -name '_*' -prune -name _manifests -printf '%h\n')

if [ "$repos" -eq 0 ]; then
    echo "No repositories under $REGISTRY_REPOS — wrong path?" >&2
    exit 1
fi

verb=Untagged; [ "$DRY_RUN" = true ] && verb="Would untag"
log "${verb} ${total_untagged} sha tag(s) across ${repos} repositories (keeping the newest ${keep_n} per repository and anything pushed in the last ${days} days)"
exit "$failed"
