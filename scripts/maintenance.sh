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
# IMPORTANT: the runner shares this host's Docker daemon with the production
# stack (see docker-compose.yml — /var/run/docker.sock is mounted into the
# runner). Everything here is therefore an operation on production, and is
# deliberately conservative:
#   - volumes are never touched (prod-mongodb, prod-qdrant and prod-redis data
#     live in them);
#   - containers are never removed (exited one-shots like prod-migrate and
#     stage-migrate are kept on purpose — they hold the last run's logs, and
#     removing them would also unpin their images);
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
# Exit code is non-zero if any step failed, so cron mails and any monitoring
# that watches exit status actually learns about it.

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

# Above this usage the routine pass is not enough and the run escalates.
DISK_ESCALATE_PCT="${DISK_ESCALATE_PCT:-85}"

GITLAB_CONTAINER="${GITLAB_CONTAINER:-gitlab}"

WITH_REGISTRY_GC=false
for arg in "$@"; do
    case "$arg" in
        --with-registry-gc) WITH_REGISTRY_GC=true ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
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

registry_running() {
    docker exec "$GITLAB_CONTAINER" gitlab-ctl status registry 2>/dev/null | grep -q '^run:'
}

run_registry_gc() {
    if ! docker ps --format '{{.Names}}' | grep -qx "$GITLAB_CONTAINER"; then
        fail "Container '$GITLAB_CONTAINER' is not running — skipped registry GC entirely"
        return
    fi

    log "Running registry garbage collection (registry stops for the duration)..."
    if docker exec "$GITLAB_CONTAINER" gitlab-ctl registry-garbage-collect -m >>"$LOG_FILE" 2>&1; then
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
    if docker exec "$GITLAB_CONTAINER" gitlab-ctl start registry >>"$LOG_FILE" 2>&1 && registry_running; then
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
    # Into the log, not just stdout: a run that always skips is indistinguishable
    # from a cron that never fires if it leaves no trace where anyone looks.
    log "Another maintenance run holds the lock — exiting" >>"$LOG_FILE"
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

if [ -t 1 ]; then
    # A pipeline puts main in a subshell, so its FAILED never reaches here —
    # take the status off PIPESTATUS instead of reading the variable.
    set +e
    main 2>&1 | tee -a "$LOG_FILE"
    FAILED=${PIPESTATUS[0]}
    set -e
else
    # Non-interactive (cron): the log file is the record, and stdout stays empty
    # so cron only mails when something actually went wrong. No pipeline here,
    # so main runs in this shell and sets FAILED directly.
    main >>"$LOG_FILE" 2>&1 || FAILED=1
    if [ "$FAILED" -ne 0 ]; then
        echo "gitlab maintenance finished with failures — see $LOG_FILE" >&2
    fi
fi

exit "$FAILED"
