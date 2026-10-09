#!/bin/bash
# Tell the ops Telegram chat when the root filesystem is filling up — before
# the registry starts answering 500 to pushes, not after — and keep the same
# alert open in the backoffice (notify-backoffice.sh) until the disk clears.
#
# Both times this disk reached 100% (2026-09-11 and 2026-10-08) the first sign
# anyone saw was a failed pipeline: pushes rejected, then a production deploy
# that did not happen. The nightly maintenance run had been logging
# "needs a human" for three nights before the second one, into a log nobody
# reads, with cron mail going to a host that has no MTA.
#
# Levels, by `df /` usage:
#   warn  >= DISK_WARN_PCT  (85, the same line maintenance.sh escalates at)
#   crit  >= DISK_CRIT_PCT  (95)
# A message goes out when the level changes, in either direction, and again
# every DISK_ALERT_REPEAT_HOURS (6) while usage stays at or above the warn line.
# Going back to ok needs the usage to fall below DISK_ALERT_CLEAR_PCT (80), so a
# disk hovering at the warn line does not alternate "warn" and "resolved" every
# 15 minutes. Between the two lines the level holds at warn and nothing repeats;
# only a drop from crit into that band is announced, as a change.
#
# Telegram is the channel that has to get through. State is one line in
# STATE_FILE whose level and timestamp move only after Telegram took the
# message: a failed send is retried on the next run, to both channels, instead
# of being forgotten.
#
# The backoffice goes first and never holds Telegram back. Its alert is key
# disk-root: warn and crit fire it with severity warning and critical, and
# falling below the clear line resolves it. If it does not take the alert, the
# Telegram message says so, because cron's stderr reaches nobody on this host.
# A failure worth retrying (no answer, 5xx) also marks the state "backoffice
# behind": the next run sends the backoffice the current level again, and
# Telegram nothing. A refusal (bad token, 4xx) is not retried — sending the same
# again cannot help.
#
# Exit code is non-zero if a channel that is on did not take the alert.
#
# Run from cron every 15 minutes (`make install-cron`). By hand it prints what
# it decided.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
DISK_CRIT_PCT="${DISK_CRIT_PCT:-95}"
DISK_ALERT_CLEAR_PCT="${DISK_ALERT_CLEAR_PCT:-80}"
DISK_ALERT_REPEAT_HOURS="${DISK_ALERT_REPEAT_HOURS:-6}"
STATE_FILE="${DISK_ALERT_STATE:-/var/lib/gitlab-disk-alert/state}"

for v in DISK_WARN_PCT DISK_CRIT_PCT DISK_ALERT_CLEAR_PCT DISK_ALERT_REPEAT_HOURS; do
    case "${!v}" in
        ''|*[!0-9]*|????*)
            echo "$v must be a whole number of at most 3 digits, got '${!v}'" >&2
            exit 2
            ;;
    esac
done

used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ -z "$used" ]; then
    echo "could not read disk usage of /" >&2
    exit 1
fi
used=$((10#$used))

prev=ok last=0 behind=0 hold=false
if [ -r "$STATE_FILE" ]; then
    read -r prev last behind <"$STATE_FILE" || true
    case "$prev" in ok|warn|crit) ;; *) prev=ok ;; esac
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    # A state file from before the backoffice existed has no third field.
    case "$behind" in 1) ;; *) behind=0 ;; esac
fi

if [ "$used" -ge "$((10#$DISK_CRIT_PCT))" ]; then
    level=crit
elif [ "$used" -ge "$((10#$DISK_WARN_PCT))" ]; then
    level=warn
elif [ "$prev" != ok ] && [ "$used" -ge "$((10#$DISK_ALERT_CLEAR_PCT))" ]; then
    # Below warn but not yet below clear: hold.
    level=warn
    hold=true
else
    level=ok
fi

now=$(date +%s)
repeat=$(( 10#$DISK_ALERT_REPEAT_HOURS * 3600 ))

send=false
if [ "$level" != "$prev" ]; then
    send=true
elif [ "$level" != ok ] && [ "$hold" = false ] && [ $((now - last)) -ge "$repeat" ]; then
    send=true
fi

echo "disk at ${used}%: level ${level} (was ${prev}), send=${send}"
if [ "$send" = false ] && [ "$behind" = 0 ]; then
    exit 0
fi

# The first line is also the backoffice alert's title, the rest its text.
case "$level" in
    crit) title="CRITICAL: disk at ${used}% (>= ${DISK_CRIT_PCT}%). Registry pushes fail at 100%: free space now." severity=critical ;;
    warn) title="WARNING: disk at ${used}% (warns from ${DISK_WARN_PCT}%, clears below ${DISK_ALERT_CLEAR_PCT}%)." severity=warning ;;
    ok)   title="RESOLVED: disk back to ${used}% (< ${DISK_ALERT_CLEAR_PCT}%)." severity= ;;
esac
details=$(df -h / | tail -1)
if [ "$level" != ok ]; then
    details="${details}
Look first at: du -sh $(cd "$SCRIPT_DIR/.." && pwd)/data/gitlab/data/gitlab-rails/shared/registry ; docker system df ; tail -30 /var/log/gitlab-maintenance.log"
fi

# Puts the current level in the backoffice. Sets bo_rc to the sender's exit
# code (0 taken, 3 channel off, 75 worth retrying, else refused) and bo_why to
# the reason it printed.
backoffice() {
    local why rc=0
    if [ "$level" = ok ]; then
        why=$("$SCRIPT_DIR/notify-backoffice.sh" disk-root resolved 2>&1 >/dev/null) || rc=$?
    else
        why=$("$SCRIPT_DIR/notify-backoffice.sh" disk-root firing "$severity" "$title" "$details" 2>&1 >/dev/null) || rc=$?
    fi
    bo_rc=$rc
    why=${why##*$'\n'}
    bo_why=${why#notify-backoffice: }
}

if [ "$send" = false ]; then
    # Telegram already has this level; only the backoffice missed it. Its
    # timestamp stays, so Telegram's repeat comes when it was due anyway.
    echo "the backoffice missed this level — sending it again"
    backoffice
    if [ "$bo_rc" -eq 75 ]; then
        echo "backoffice: $bo_why" >&2
        exit 1
    fi
    echo "$level $last 0" >"$STATE_FILE"
    case "$bo_rc" in
        0|3) exit 0 ;;
        *) echo "backoffice: $bo_why" >&2; exit 1 ;;
    esac
fi

backoffice
msg="${title}
${details}"
case "$bo_rc" in
    0|3) ;;
    75) msg="${msg}
Backoffice not updated, retried on the next run: ${bo_why}" ;;
    *)  msg="${msg}
Backoffice not updated: ${bo_why}" ;;
esac

if ! "$SCRIPT_DIR/notify-telegram.sh" "$msg"; then
    # Telegram's level and timestamp stay as they were, so the next run sends
    # it again. The backoffice may have this level already; if the disk goes
    # back to the recorded level before then, only a resend of the current
    # level puts the backoffice right, so it is marked behind. A refusal stays
    # unmarked: the same request again cannot help.
    if [ "$bo_rc" -eq 0 ] || [ "$bo_rc" -eq 75 ]; then
        mkdir -p "$(dirname "$STATE_FILE")"
        echo "$prev $last 1" >"$STATE_FILE"
    fi
    exit 1
fi

behind=0
if [ "$bo_rc" -eq 75 ]; then
    behind=1
fi
mkdir -p "$(dirname "$STATE_FILE")"
echo "$level $now $behind" >"$STATE_FILE"
case "$bo_rc" in
    0|3) ;;
    *) echo "backoffice: $bo_why" >&2; exit 1 ;;
esac
