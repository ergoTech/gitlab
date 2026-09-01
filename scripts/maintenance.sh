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
#     data live in them, as do the runner's caches). The anonymous volumes of a
#     removed CI build container go with it — `docker rm -v` cannot reach a
#     named volume, so this is bounded to the container's own scratch;
#   - containers are removed in ONE case only: a CI build container (name
#     `runner-*`) that exited longer ago than BUILD_CONTAINER_RETENTION_HOURS.
#     Everything else is kept, including exited one-shots such as prod-migrate
#     and stage-migrate on a host that has them — they hold their last run's
#     logs, and removing them would unpin their images;
#   - images are only ever pruned with an age filter, so an image built seconds
#     ago by a running pipeline and not yet pushed cannot be swept from under it.
#
# Run daily via cron for 2, weekly for 1 (registry GC stops the registry for the
# duration, so it is not something to do every night). See `make install-cron`.
#
# Usage:
#   ./scripts/maintenance.sh                     # docker + journal only
#   ./scripts/maintenance.sh --with-registry-gc  # everything
#
# Exit code is non-zero if any step failed, so monitoring that watches exit
# status learns about it. Cron mails for a different reason — it mails on
# OUTPUT, and the failure line goes to stderr while the cron entries discard
# stdout.

set -euo pipefail

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

LOCK_FILE="${MAINTENANCE_LOCK:-/var/lock/gitlab-maintenance.lock}"
LOG_FILE="${MAINTENANCE_LOG:-/var/log/gitlab-maintenance.log}"
LOG_MAX_BYTES=$((10 * 1024 * 1024))

# Images CREATED longer ago than this may be pruned when nothing references
# them. Note this is creation time, not last-used time — that is what Docker's
# `until` filter means, and a base image pulled today can be years old by it.
# The point of the window is narrower than "keep what we still need": it is to
# guarantee an image a pipeline just built is never removed before it is pushed.
IMAGE_RETENTION="${IMAGE_RETENTION:-168h}"

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

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

fail() {
    FAILED=1
    log "${RED}$*${NC}"
}

disk_used_pct() {
    df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9'
}

disk_line() {
    df -h / | tail -1
}

# A CI job holds images that exist only on this host until `docker push`
# succeeds. Pruning during one can delete a freshly built image between build
# and push, which fails the pipeline at exactly the step this script exists to
# keep working.
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

registry_running() {
    docker exec "$GITLAB_CONTAINER" gitlab-ctl status registry 2>/dev/null | grep -q '^run:'
}

run_registry_gc() {
    if ! docker ps --format '{{.Names}}' | grep -qx "$GITLAB_CONTAINER"; then
        fail "Container '$GITLAB_CONTAINER' is not running — skipped registry GC entirely"
        return
    fi

    log "Running registry garbage collection (registry stops for the duration)..."
    if docker exec "$GITLAB_CONTAINER" gitlab-ctl registry-garbage-collect -m 2>&1; then
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

main() {
    log "${YELLOW}=== Maintenance start (registry_gc=${WITH_REGISTRY_GC}) ===${NC}"
    log "Before: $(disk_line)"

    if ci_job_running; then
        log "${YELLOW}A CI job is running — skipping image pruning this pass${NC}"
    else
        # Before the prunes, not after: removing these is what makes the images
        # they were holding eligible in this same run rather than the next one.
        remove_abandoned_build_containers

        log "Pruning buildkit cache older than ${IMAGE_RETENTION}..."
        docker builder prune -af --filter "until=${IMAGE_RETENTION}" >/dev/null 2>&1 ||
            fail "builder prune failed"

        log "Pruning unreferenced images created more than ${IMAGE_RETENTION} ago..."
        docker image prune -af --filter "until=${IMAGE_RETENTION}" >/dev/null 2>&1 ||
            fail "image prune failed"
    fi

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

    if [ "$used" -ge "$DISK_ESCALATE_PCT" ]; then
        if ci_job_running; then
            fail "Disk at ${used}% but a CI job is running — NOT escalating, rerun after it finishes"
        else
            log "${RED}Disk at ${used}% (>= ${DISK_ESCALATE_PCT}%) — escalating to images older than ${ESCALATION_RETENTION}${NC}"
            docker image prune -af --filter "until=${ESCALATION_RETENTION}" >/dev/null 2>&1 ||
                fail "escalated image prune failed"
            used=$(disk_used_pct) || used=0
            [ -n "$used" ] || used=0
            if [ "$used" -ge "$DISK_ESCALATE_PCT" ]; then
                fail "Disk STILL at ${used}% after escalation — needs a human"
            fi
        fi
    fi

    log "After:  $(disk_line)"
    if [ "$FAILED" -eq 0 ]; then
        log "${GREEN}=== Maintenance done ===${NC}"
    else
        log "${RED}=== Maintenance finished WITH FAILURES ===${NC}"
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
