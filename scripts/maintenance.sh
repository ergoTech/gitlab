#!/bin/bash
# Disk maintenance for the GitLab host.
#
# Two things fill this disk, and neither cleans up after itself:
#
#   1. The container registry. Every pipeline pushes the same :latest tag, which
#      leaves the previous manifest untagged. Untagged manifests and their blobs
#      stay on disk forever unless garbage collection runs with -m. On this host
#      that reached 41 GB before anyone noticed — the registry then answers 500
#      to every blob upload, so every pipeline fails at the push step while the
#      build itself is green, which reads like a broken build and is not one.
#      Master builds also push a :<short-sha> tag, and a tagged image is never
#      collected. GitLab's cleanup policies cannot untag a multi-arch one on
#      this registry (registry-prune-tags.sh says why), and backend/core's are
#      all multi-arch; the registry stood at 94 GB by 2026-10-08. So the GC
#      pass untags old sha tags itself first.
#
#   2. The runner's Docker state. Multiarch builds leave buildkit cache and an
#      unreferenced image per pipeline: 14.85 GB of cache and 56 GB of images
#      from 507 images of which 26 were in use.
#
# IMPORTANT: /var/run/docker.sock is mounted into the runner, so everything here
# operates on whatever else shares that daemon. On the original host that was the
# production stack itself — which is where the caution below comes from, and why
# it is kept even though the GitLab host this now runs on has nothing but gitlab
# and gitlab-runner on its daemon. Deliberately conservative:
#   - NAMED volumes are never touched (prod-mongodb, prod-qdrant and prod-redis
#     data live in them), with one exception: the runner's own cache volumes
#     (`runner-*-cache-<hash>`), and only as the last step of an escalation
#     that everything else failed to bring under the line — see
#     remove_unused_runner_cache_volumes. The anonymous volumes of a removed CI
#     build container go with it — `docker rm -v` cannot reach a named volume,
#     so this is bounded to the container's own scratch;
#   - containers are removed in ONE case only: a CI build container (name
#     `runner-*`) that exited longer ago than BUILD_CONTAINER_RETENTION_HOURS,
#     on a pass that finds no CI job running.
#     Everything else is kept, including exited one-shots such as prod-migrate
#     and stage-migrate on a host that has them — they hold their last run's
#     logs, and removing them would unpin their images;
#   - images and build cache are only ever pruned behind an age window, and that
#     window, not a check for running CI jobs, is what keeps a tag a pipeline has
#     just built from being swept before it is pushed. What it does not cover —
#     a reused tag such as :latest, among others — is spelled out at
#     prune_images_and_build_cache.
#
# Run daily via cron for 2, weekly for 1 (registry GC stops the registry for the
# duration, so it is not something to do every night) — and for 1 on any night
# the disk is past DISK_ESCALATE_PCT. See `make install-cron`.
#
# Usage:
#   ./scripts/maintenance.sh                     # docker + journal only
#   ./scripts/maintenance.sh --with-registry-gc  # everything
#
# Exit code is non-zero if any step failed, so monitoring that watches exit
# status learns about it. Cron mails for a different reason — it mails on
# OUTPUT, and the failure line goes to stderr while the cron entries discard
# stdout. The GitLab host has no MTA, though, so that mail goes nowhere; a run
# with failures also sends them to Telegram (notify-telegram.sh).

set -euo pipefail

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

LOCK_FILE="${MAINTENANCE_LOCK:-/var/lock/gitlab-maintenance.lock}"
LOG_FILE="${MAINTENANCE_LOG:-/var/log/gitlab-maintenance.log}"
LOG_MAX_BYTES=$((10 * 1024 * 1024))

# Build cache and images older than this may be pruned when nothing uses them.
# "Older" is measured two ways, and neither is the CREATED column of
# `docker images`:
#   - build cache: time since it was last USED (buildkit's keep-duration, which
#     buildx also still accepts under its old name, `unused-for`);
#   - images: time since the image's NAME was created on this host, by the build
#     that first tagged it or the pull that first fetched it. That is the
#     containerd image store, which this host runs (`docker info` reports
#     driver-type io.containerd.snapshotter.v1). The classic graphdriver store
#     compared the image's own created field instead — the CREATED column, by
#     which a base image pulled today can be years old.
# Checked on 2026-09-11 against Docker 29.7.2 with the containerd store, the
# version this host runs. One build tagged the same image twice: a new tag, and
# one an earlier build had created just over a minute before. Under until=1m
# the new tag survived and the older one was pruned. Build cache created just
# over a minute before, but reused seconds before, survived.
#
# The point of the window is narrower than "keep what we still need": it is to
# keep a tag a pipeline just built from being removed before it is pushed. It
# does that for a new tag from an ordinary build; the cases it does not cover
# are listed at prune_images_and_build_cache.
#
# 24h, down from the 168h this started with. Like BUILD_CONTAINER_RETENTION_HOURS
# below, this is sampled by a 03:30 cron, so an unused image lives up to N+24
# hours: two days at 24h, eight at 168h. And on a host that starts empty, 168h
# is a week in which nothing is old enough to go: the nightly runs from
# 2026-09-02 to 09-07 freed 2 GB at most while the disk went from 57% to 71%;
# the first prune after that week, on 09-09, freed 13 GB. The price of the
# shorter window: build cache idle for a day goes, so the first build after a
# quiet weekend runs cold, and a CI image nothing is running at 03:30 — a
# service image such as mongo:8 — goes once its name is a day old and is
# downloaded again by the next job that needs it.
IMAGE_RETENTION="${IMAGE_RETENTION:-24h}"

# Escalation keeps a window too, for exactly the same reason. One hour is far
# longer than any build-to-push gap here and still sweeps everything old.
ESCALATION_RETENTION="${ESCALATION_RETENTION:-1h}"

# Hours after a CI build container EXITS before it may be removed. A number of
# hours rather than a docker duration string, unlike its neighbours above,
# because `docker ps` has no `until` filter — the age has to be computed here.
#
# Eight, not twenty-four, because this is sampled by a 03:30 cron: a window of N
# hours means anything that died after 03:30-N waits for the NEXT night, so 24
# really means 24-48. The ten containers that prompted this function were 11-16
# hours old at the following run and a 24h window would have skipped every one
# of them. Nothing needs a long window here: ci_job_running already holds off
# while any job is live, and the runner is concurrent = 1.
BUILD_CONTAINER_RETENTION_HOURS="${BUILD_CONTAINER_RETENTION_HOURS:-8}"

# Above this usage the routine pass is not enough and the run escalates.
DISK_ESCALATE_PCT="${DISK_ESCALATE_PCT:-85}"

GITLAB_CONTAINER="${GITLAB_CONTAINER:-gitlab}"

WITH_REGISTRY_GC=false
for arg in "$@"; do
    case "$arg" in
        --with-registry-gc) WITH_REGISTRY_GC=true ;;
        # Everything from line 2 to the first non-comment line, computed rather
        # than hardcoded: the previous `sed -n '2,36p'` silently stopped covering
        # --with-registry-gc the moment the header grew by three lines, so --help
        # stopped documenting the flag the Sunday cron uses.
        -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

FAILED=0
FAIL_MESSAGES=()
REGISTRY_GC_DONE=false
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

fail() {
    FAILED=1
    FAIL_MESSAGES+=("$*")
    log "${RED}$*${NC}"
}

disk_used_pct() {
    df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9'
}

disk_line() {
    df -h / | tail -1
}

# True while any CI build container is up. It holds back removing CI build
# containers, decides whether a leftover buildx builder is worth reporting, and
# marks in the log an escalation that ran during a job. It does NOT hold back the
# image and build-cache prunes any more; prune_images_and_build_cache has what
# protects a live job from those, and what does not.
ci_job_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^runner-'
}

# GitLab Runner removes its own build containers when a job ends. Ones that
# survive are from a job that did NOT end — a killed runner, a restarted daemon
# — and they are not merely debris: an exited container still references the
# images it used, so the image prune below cannot touch those images while it is
# here. Measured on the GitLab host, 2026-09-01, ten leftovers from two
# interrupted builds. `docker system df` before and after removing them:
#
#   Containers   4.156GB / 4.149GB reclaimable  ->  6.595MB / 0B
#   Images      13.76GB  / 3.858GB reclaimable  -> 13.76GB  / 6.87GB
#
# Two effects, worth not conflating: 4.15 GB of container layers is freed
# outright by the removal, and a further ~3.0 GB of images stops being pinned.
# Only the first is a reclaim; the second is a reclassification that the prune
# below may or may not act on, depending on its age filter.
#
# Deliberately narrow, and each half of the filter earns its place:
#   - `^runner-` only, so the exited one-shots this script has always protected
#     (prod-migrate and friends on a host that shares its daemon with production)
#     and the buildx builders reported further down are both untouched;
#   - exited only, so nothing a live job owns is in scope;
#   - older than the window, so a job whose helper is still uploading artifacts
#     is safe even if ci_job_running has already gone false.
remove_abandoned_build_containers() {
    local cutoff now hours finished fin_epoch rm_err removed=0 skipped=0 c

    # Validated rather than trusted, because this one is arithmetic: a value
    # like `24h` — the format both neighbouring knobs use — would abort the
    # whole run under `set -u`, taking the image prune, the journal vacuum and
    # the registry restart-if-down safety net with it. A bad IMAGE_RETENTION
    # only ever fails its own docker call.
    # Three shapes are rejected, and the second two are not pedantry:
    #   - non-numeric, the `24h` typo the neighbouring knobs invite;
    #   - seven digits or more, which is 114 years and up. That is a nonsense
    #     window on its own, but the cap is also where the arithmetic stops
    #     being trustworthy: measured in bash, 7 to 15 digits drive the cutoff
    #     deeply negative and fail CLOSED (everything is skipped), while from 16
    #     digits `H * 3600` wraps int64 and the cutoff lands in the FUTURE — the
    #     guard fails OPEN and sweeps containers that exited seconds ago.
    # A leading zero is not rejected but normalised below: `$(( 08 ))` is an
    # octal error that would abort the whole run, and `$(( 010 ))` is a silent 8.
    case "$BUILD_CONTAINER_RETENTION_HOURS" in
        ''|*[!0-9]*|???????*)
            fail "BUILD_CONTAINER_RETENTION_HOURS must be a whole number of hours, at most 6 digits, got '${BUILD_CONTAINER_RETENTION_HOURS}' — skipping this step"
            return
            ;;
    esac

    # 10# forces base ten. Logged from `hours`, not from the raw variable, so the
    # message cannot say 010h while the arithmetic uses 8.
    hours=$(( 10#$BUILD_CONTAINER_RETENTION_HOURS ))
    now=$(date +%s)
    cutoff=$(( now - hours * 3600 ))

    for c in $(docker ps -aq --filter 'name=^runner-' --filter 'status=exited' 2>/dev/null); do
        finished=$(docker inspect "$c" --format '{{.State.FinishedAt}}' 2>/dev/null) || continue
        # Note what does NOT protect a never-run container here: GNU date parses
        # the zero timestamp 0001-01-01T00:00:00Z happily (it returns
        # -62135596800 with status 0), so this would sail past any cutoff. What
        # keeps them out is `status=exited` in the filter above — a container
        # that never ran is `created`, not `exited`. If that filter is ever
        # widened, this needs a zero-timestamp guard of its own.
        #
        # The residual case is an exited container whose FinishedAt is zero
        # because the daemon died mid-write — the very scenario this function
        # exists for. It would be removed regardless of age. Deliberate: it is
        # abandoned by definition, and ci_job_running already guards live work.
        fin_epoch=$(date -d "$finished" +%s 2>/dev/null) || continue
        if [ "$fin_epoch" -ge "$cutoff" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if rm_err=$(docker rm -v "$c" 2>&1 >/dev/null); then
            removed=$((removed + 1))
        else
            case "$rm_err" in
                # The runner reaping its own container between the listing and
                # this line is normal, not a failure worth waking anyone for.
                *"No such container"*) : ;;
                *) fail "could not remove abandoned CI build container $c: $rm_err" ;;
            esac
        fi
    done

    if [ "$removed" -gt 0 ]; then
        log "Removed ${removed} abandoned CI build container(s) that exited over ${hours}h ago"
    fi
    # Reported even when nothing was removed, matching the buildx block further
    # down: an admin asking why the disk is full should not have to infer that
    # this step ran and declined.
    if [ "$skipped" -gt 0 ]; then
        log "${YELLOW}${skipped} exited CI build container(s) younger than ${hours}h — left alone${NC}"
    fi
}

# Build cache, then images, both behind the same window. This runs whether or
# not a CI job is live, and that is a decision, not an oversight.
#
# It used to be skipped for the whole pass whenever any runner-* container was
# up. The log has that skip on four of the ten nights up to 2026-09-11 — 09-04,
# 09-08, 09-10 and 09-11 — and on the 11th, at 93%, the run would not escalate
# either. The disk reached 100% that day, and GitLab refused every push to
# every project until the images and build cache were pruned by hand.
#
# What keeps a live pipeline safe without that check:
#   - docker never prunes the tag a container was created from, running or
#     stopped — only that tag: other tags of the same image can go, and a build
#     that later moves the tag takes the protection with it — nor build cache
#     that a running build holds;
#   - a tag a build has just created stays younger than either window for far
#     longer than any push here takes (IMAGE_RETENTION has how age is counted).
#
# Three cases fall through, and they are the price of the choice. Each can fail
# the job it hits, and a retry fixes it, since the prune runs once a night:
#   - a REUSED tag. `docker build -t X:latest` over an existing X:latest updates
#     the tag in place and keeps its first creation time, so until the job has
#     pushed it, or used it by name in any other way, the tag can be older than
#     the window with nothing using it. build/base's build-latest is exactly
#     that: it builds :latest and :sha together and pushes :latest last, so a
#     prune in that gap fails it at a push, with the registry's :latest still
#     on the previous image. On a re-run of the same commit, :sha can be a
#     reused tag too;
#   - a build with SOURCE_DATE_EPOCH set, as a build-arg or just in the job's
#     environment, which buildx passes on. The new tag is then dated by that
#     epoch, not by the build, so once the epoch is older than the window the
#     tag is unprotected from the start;
#   - a pull in flight. `docker image prune` begins by deleting the leases that
#     in-flight pulls hold, so what a pull has fetched but not yet named can go
#     whatever its age; and a re-pull keeps the name's first creation time, so
#     an idle image past the window can lose its name between the pull and the
#     container that was about to use it.
# The old check covered all three for a job that already had a container up
# when the run began — not one that started during the run, nor a job still
# pulling before its first container.
#
# Waiting for an idle moment instead would make these rarer, not impossible: a
# night busy enough to need the wait times out into exactly this. It would cost
# a timeout to tune, a run that holds the lock for the whole wait, and a Sunday
# registry GC pushed later into the morning — all to avoid a retried job, where
# the skip it replaces cost a full disk.
prune_images_and_build_cache() {
    local window=$1 label=$2

    log "Pruning build cache not used in the last ${window}..."
    docker builder prune -af --filter "until=${window}" >/dev/null 2>&1 ||
        fail "${label}builder prune failed"

    log "Pruning unused images first tagged or pulled over ${window} ago..."
    docker image prune -af --filter "until=${window}" >/dev/null 2>&1 ||
        fail "${label}image prune failed"
}

registry_running() {
    docker exec "$GITLAB_CONTAINER" gitlab-ctl status registry 2>/dev/null | grep -q '^run:'
}

# The collector logs one line per blob and manifest it marks or finds eligible:
# over 12,000 lines of the 2026-10-04 run were still in this log five days
# later, most of it, pushing real history out at the 10 MB trim. The stage
# summaries ("mark stage complete blobs_marked=… blobs_to_delete=…", "blobs
# deleted count=…") are kept.
GC_NOISE='msg="(marking blob|marking manifest|blob eligible for deletion|manifest eligible for deletion)"'

run_registry_gc() {
    # Set before the check, so a pass that already failed here does not try
    # again from the escalation and report the same failure twice.
    REGISTRY_GC_DONE=true
    if ! docker ps --format '{{.Names}}' | grep -qx "$GITLAB_CONTAINER"; then
        fail "Container '$GITLAB_CONTAINER' is not running — skipped registry GC entirely"
        return
    fi

    # Untag with the registry already stopped, so no push can rewrite a tag
    # while it goes. registry-garbage-collect stops it too (a no-op by then) and
    # starts it again when it finishes, whether or not it succeeded.
    #
    # Between this stop and that start, the registry is down on this script's
    # account alone: a Ctrl-C, or the HUP of a dropped ssh session during
    # `make maintenance`, would leave it down until some later run noticed. The
    # trap starts it back up on the way out. It is armed before the stop: the
    # stop is a docker exec that finishes inside the container even if this
    # script dies mid-call, and starting a registry that is still up is a
    # no-op. It is cleared BEFORE the GC call, not after: once GC runs,
    # gitlab-ctl inside the container owns the restart (killing the docker exec
    # client does not stop it), and starting the registry under a running sweep
    # is exactly what stopping it prevents.
    #
    # PIPE is in the list for a reason that is easy to miss: main runs as
    # `main 2>&1 | tee`, and the same Ctrl-C or HUP kills tee too. The next
    # thing this shell writes — bash's own "Terminated" notice for the killed
    # child comes first — then raises SIGPIPE, which by default kills it before
    # the INT/TERM/HUP handler ever runs. Measured in bash 5.2: without PIPE
    # here, a TERM to the process group left the registry stopped.
    log "Stopping the registry — pushes fail until GC is done..."
    trap 'docker exec "$GITLAB_CONTAINER" gitlab-ctl start registry >/dev/null 2>&1; exit 130' INT TERM HUP PIPE
    if docker exec "$GITLAB_CONTAINER" gitlab-ctl stop registry >/dev/null 2>&1; then
        log "Untagging old sha tags..."
        "$SCRIPT_DIR/registry-prune-tags.sh" 2>&1 ||
            fail "Registry tag pruning failed — GC runs anyway, on whatever was untagged"
    else
        fail "Could not stop the registry — skipping tag pruning, running GC alone"
    fi

    # This line before `trap -`, not after: with tee already gone, it is the
    # write that raises SIGPIPE, and it must do so while the trap still holds.
    log "Running registry garbage collection..."
    trap - INT TERM HUP PIPE
    local gc_rc=0
    docker exec "$GITLAB_CONTAINER" gitlab-ctl registry-garbage-collect -m 2>&1 |
        { grep -vE "$GC_NOISE" || :; } || gc_rc=$?
    if [ "$gc_rc" -eq 0 ]; then
        log "${GREEN}Registry GC done${NC}"
    else
        fail "Registry GC FAILED — see $LOG_FILE"
    fi

    # gitlab-ctl stops the registry before collecting and starts it afterwards.
    # An interrupted run (reboot, OOM, daemon restart) leaves it stopped, and a
    # stopped registry fails every push with the same symptom as a full disk.
    # Never end this function without knowing which state it is in.
    if registry_running; then
        return
    fi
    fail "Registry is DOWN after GC — starting it"
    if docker exec "$GITLAB_CONTAINER" gitlab-ctl start registry 2>&1 && registry_running; then
        log "${GREEN}Registry restarted${NC}"
    else
        fail "Could not restart the registry — PUSHES ARE FAILING, fix by hand: docker exec $GITLAB_CONTAINER gitlab-ctl start registry"
    fi
}

# The runner's cache volumes, `runner-<runner hash>-cache-<path hash>` with an
# optional `-protected`, that no container references. The last resort of an
# escalation and nothing else: in normal running they are bounded by the
# templates (build/base drops Go cache entries unused for a day). On
# 2026-10-08 local volumes stood at 19.8 GB, almost all of it in 22 runner
# cache volumes that had to be removed by hand.
#
# What it costs is a cold cache: the next job of each project starts without
# its Go build cache or /builds checkout, and is slower once. No pipeline here
# keeps correctness in a runner cache — build/base has no `cache:` any more,
# and site, backoffice and the MCP plugin run `npm ci` in every job.
#
# A volume a running job uses is referenced by its container, so it is not
# dangling and is not listed; one the daemon still refuses is skipped, not a
# failure. The residual race is a job that has created its volume but not yet
# the container that mounts it — at worst that job starts cold or fails once,
# and a retry fixes it.
# Anonymous volumes are left alone: what is in them is not known.
remove_unused_runner_cache_volumes() {
    local v removed=0
    for v in $(docker volume ls -q --filter dangling=true 2>/dev/null |
               grep -E '^runner-.*-cache-[0-9a-f]{32}(-protected)?$' || true); do
        if docker volume rm "$v" >/dev/null 2>&1; then
            removed=$((removed + 1))
        fi
    done
    log "Removed ${removed} unused runner cache volume(s)"
}

main() {
    log "${YELLOW}=== Maintenance start (registry_gc=${WITH_REGISTRY_GC}) ===${NC}"
    log "Before: $(disk_line)"

    # Containers keep the old rule and wait for a pass with no CI job running;
    # the prunes after them do not wait — prune_images_and_build_cache says why.
    if ci_job_running; then
        log "${YELLOW}A CI job is running — leaving abandoned CI build containers for an idle pass, pruning build cache and images anyway${NC}"
    else
        # Before the prunes, not after: removing these is what makes the images
        # they were holding eligible in this same run rather than the next one.
        remove_abandoned_build_containers
    fi

    prune_images_and_build_cache "$IMAGE_RETENTION" ""

    # The multiarch pipeline creates a docker-container buildx builder and drops
    # it in after_script; its cache lives in that builder, not in the daemon's,
    # so the prune above does not reach it. A leftover means a job died — report
    # it rather than removing it, since a live build may still own it.
    if ! ci_job_running; then
        local stale
        stale=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^buildx_buildkit_' || true)
        if [ -n "$stale" ]; then
            log "${YELLOW}Leftover buildx builder(s) holding cache, no CI job running:${NC}"
            log "$stale"
            log "${YELLOW}Remove with: docker buildx rm <builder-name>${NC}"
        fi
    fi

    log "Vacuuming systemd journal..."
    journalctl --vacuum-size=500M >/dev/null 2>&1 || fail "journal vacuum failed"

    if [ "$WITH_REGISTRY_GC" = true ]; then
        run_registry_gc
    fi

    local used
    used=$(disk_used_pct) || used=0
    if [ -z "$used" ]; then used=0; fi

    # Escalation prunes build cache as well as images: on 2026-09-11 the build
    # cache was the larger half of what had to go by hand (11.82 GB, against
    # 10.24 GB of images). And it escalates while a CI job runs too — the 11th
    # was exactly that night: 93%, a job running, and the old rule here
    # declined. The log line says whether a job was running, so a pipeline that
    # failed at a push at this hour can be traced back here.
    #
    # Then, one step at a time and only while still over the line: registry GC
    # with tag pruning on a night that is not Sunday, and finally the runner's
    # unused cache volumes. The registry was the step this lacked on
    # 2026-10-06..08: three nights of "needs a human" at 86-87%, with 94 GB in
    # the registry that no step here could reach, until a push failed on a
    # full disk. GC stops the registry for its duration, so a push at that
    # moment fails and needs a retry — the same trade as the image prune.
    if [ "$used" -ge "$DISK_ESCALATE_PCT" ]; then
        local during=""
        if ci_job_running; then
            during=", with a CI job running"
        fi
        log "${RED}Disk at ${used}% (>= ${DISK_ESCALATE_PCT}%) — escalating to build cache and images older than ${ESCALATION_RETENTION}${during}${NC}"
        prune_images_and_build_cache "$ESCALATION_RETENTION" "escalated "
        used=$(disk_used_pct) || used=0
        [ -n "$used" ] || used=0

        if [ "$used" -ge "$DISK_ESCALATE_PCT" ] && [ "$REGISTRY_GC_DONE" = false ]; then
            log "${RED}Disk still at ${used}% — escalating to registry tag pruning and GC${NC}"
            run_registry_gc
            used=$(disk_used_pct) || used=0
            [ -n "$used" ] || used=0
        fi

        if [ "$used" -ge "$DISK_ESCALATE_PCT" ]; then
            log "${RED}Disk still at ${used}% — escalating to unused runner cache volumes${NC}"
            remove_unused_runner_cache_volumes
            used=$(disk_used_pct) || used=0
            [ -n "$used" ] || used=0
        fi

        if [ "$used" -ge "$DISK_ESCALATE_PCT" ]; then
            fail "Disk STILL at ${used}% after escalation — needs a human"
        fi
    fi

    log "After:  $(disk_line)"
    if [ "$FAILED" -eq 0 ]; then
        log "${GREEN}=== Maintenance done ===${NC}"
    else
        log "${RED}=== Maintenance finished WITH FAILURES ===${NC}"
        local text
        text="GitLab maintenance finished with failures:"
        text+=$(printf '\n- %s' "${FAIL_MESSAGES[@]}")
        text+=$'\n'"$(disk_line)"$'\n'"Log: $LOG_FILE"
        if ! "$SCRIPT_DIR/notify-telegram.sh" "$text" 2>&1; then
            log "${RED}Could not send the failure to Telegram either${NC}"
        fi
    fi
    return "$FAILED"
}

# flock, not a PID file: the weekly and daily entries can collide, and two
# concurrent image prunes on a daemon shared with production is a good way to
# make a pipeline fail on a half-removed layer. fd 9 is released when this
# process exits, including on SIGKILL; the lock file is deliberately not
# removed, since unlinking it races the next run.
exec 9>"$LOCK_FILE"
lock_rc=0
flock -n 9 || lock_rc=$?
if [ "$lock_rc" -eq 1 ]; then
    # Both stdout and the log. A run that always skips is indistinguishable from
    # a cron that never fires if it leaves no trace where anyone looks — and a
    # hand-run that prints nothing is the very confusion this script just fixed.
    log "Another maintenance run holds the lock — exiting" | tee -a "$LOG_FILE"
    exit 0
elif [ "$lock_rc" -ne 0 ]; then
    log "Could not acquire lock ($LOCK_FILE): flock exited $lock_rc" | tee -a "$LOG_FILE" >&2
    exit 1
fi

# Trimmed under the lock and by copy-truncate, so a concurrent writer's fd keeps
# pointing at the same inode instead of writing into an unlinked one.
if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -gt "$LOG_MAX_BYTES" ]; then
    trimmed=$(tail -c $((LOG_MAX_BYTES / 2)) "$LOG_FILE") && printf '%s\n' "$trimmed" >"$LOG_FILE"
fi

# Output always goes to stdout AND the log; the cron entries redirect stdout to
# /dev/null themselves. Deciding this from `[ -t 1 ]` was worse than it looked:
# `ssh host './maintenance.sh'` has no TTY either, so a hand-run over ssh went
# completely silent and looked like it had done nothing.
#
# A pipeline puts main in a subshell, so its FAILED never reaches here — take
# the status off PIPESTATUS instead of reading the variable.
set +e
main 2>&1 | tee -a "$LOG_FILE"
# Copied as a whole array in one command: any assignment is itself a command
# and resets PIPESTATUS, so reading [0] and [1] on separate statements makes
# the second one read the wrong array — under `set -u` that is an unbound
# variable and the script dies right where it is meant to report a result.
pipe_rc=("${PIPESTATUS[@]}")
set -e
FAILED=${pipe_rc[0]}
if [ "${pipe_rc[1]:-0}" -ne 0 ]; then
    # The log is the only record a scheduled run leaves; losing it silently
    # would make every later "it ran fine" unverifiable.
    echo "could not write $LOG_FILE" >&2
    FAILED=1
fi

# stderr, so cron mails this even with stdout redirected away.
if [ "$FAILED" -ne 0 ]; then
    echo "gitlab maintenance finished with failures — see $LOG_FILE" >&2
fi

exit "$FAILED"
