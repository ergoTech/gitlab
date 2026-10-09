#!/bin/bash
# Tell the ops Telegram chat when the root filesystem is filling up — before
# the registry starts answering 500 to pushes, not after.
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
# State is one line in STATE_FILE, written only after a message was actually
# sent: a failed send is retried on the next run instead of being forgotten.
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

prev=ok last=0 hold=false
if [ -r "$STATE_FILE" ]; then
    read -r prev last <"$STATE_FILE" || true
    case "$prev" in ok|warn|crit) ;; *) prev=ok ;; esac
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
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
[ "$send" = true ] || exit 0

df_line=$(df -h / | tail -1)
case "$level" in
    crit) msg="CRITICAL: disk at ${used}% (>= ${DISK_CRIT_PCT}%). Registry pushes fail at 100%: free space now.
${df_line}" ;;
    warn) msg="WARNING: disk at ${used}% (warns from ${DISK_WARN_PCT}%, clears below ${DISK_ALERT_CLEAR_PCT}%).
${df_line}" ;;
    ok)   msg="RESOLVED: disk back to ${used}% (< ${DISK_ALERT_CLEAR_PCT}%).
${df_line}" ;;
esac
if [ "$level" != ok ]; then
    msg="${msg}
Look first at: du -sh $(cd "$SCRIPT_DIR/.." && pwd)/data/gitlab/data/gitlab-rails/shared/registry ; docker system df ; tail -30 /var/log/gitlab-maintenance.log"
fi

"$SCRIPT_DIR/notify-telegram.sh" "$msg"

mkdir -p "$(dirname "$STATE_FILE")"
echo "$level $now" >"$STATE_FILE"
