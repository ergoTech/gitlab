#!/bin/bash
# disk-alert.sh with df and both notifiers stubbed: when it sends, to which
# channel, and what the state file keeps.
set -u
. /t/lib.sh || exit 2
stub_world

export DISK_ALERT_STATE=/tmp/da/state
da() { echo "$1" >/tmp/used; bash /w/scripts/disk-alert.sh >/tmp/da.out 2>/tmp/da.err; }
reset() { rm -rf /tmp/da /tmp/sent /tmp/tg.last /tmp/bo.d /tmp/order; }
bo() { cat "/tmp/bo.d/$1"; }

########## levels — both channels on and working
reset
da 50;  check '[ $(nsent) -eq 0 ] && [ $(nbo) -eq 0 ] && [ ! -e $DISK_ALERT_STATE ]' "50%: nothing sent, no state"
da 86;  check '[ $(nsent) -eq 1 ] && grep -q "WARNING: disk at 86%" /tmp/sent' "86%: warning sent"
check 'bo 1 | grep -qx "key=disk-root status=firing severity=warning" && bo 1 | grep -qx "title=WARNING: disk at 86% (warns from 85%, clears below 80%)."' "86%: backoffice fired, severity warning, first line as title"
check 'bo 1 | grep -q "^text=/dev/sda4 " && bo 1 | grep -q "Look first at: du -sh"' "86%: backoffice text is the rest of the message"
check '[ "$(cat /tmp/order)" = "$(printf "bo firing\ntg")" ]' "86%: backoffice before Telegram"
check '! grep -q "Backoffice" /tmp/sent' "86%: no backoffice note when it took the alert"
check 'grep -Eq "^warn [0-9]+ 0$" $DISK_ALERT_STATE' "86%: state owes the backoffice nothing"
da 87;  check '[ $(nsent) -eq 1 ] && [ $(nbo) -eq 1 ]' "87%: no repeat within 6h"
echo "warn $(( $(date +%s) - 7*3600 ))" >$DISK_ALERT_STATE
da 87;  check '[ $(nsent) -eq 2 ] && [ $(nbo) -eq 2 ]' "87% after 7h, two-field state of an older version: repeated on both channels"
da 96;  check '[ $(nsent) -eq 3 ] && grep -q "CRITICAL: disk at 96%" /tmp/sent && bo 3 | grep -qx "key=disk-root status=firing severity=critical"' "96%: critical on both channels"
da 90;  check '[ $(nsent) -eq 4 ] && grep -q "WARNING: disk at 90%" /tmp/sent && bo 4 | grep -q "severity=warning"' "90%: downgrade to warning sent"
da 82;  check '[ $(nsent) -eq 4 ] && [ $(nbo) -eq 4 ] && grep -q "^warn " $DISK_ALERT_STATE' "82%: held at warn, silent"
da 79;  check '[ $(nsent) -eq 5 ] && grep -q "RESOLVED: disk back to 79%" /tmp/sent && bo 5 | grep -qx "key=disk-root status=resolved severity="' "79%: resolved on both channels"
da 79;  check '[ $(nsent) -eq 5 ] && [ $(nbo) -eq 5 ]' "79% again: silent"
echo 88 >/tmp/used; TG_FAIL=1 bash /w/scripts/disk-alert.sh >/dev/null 2>&1; rc=$?
check '[ $rc -ne 0 ] && grep -q "^ok " $DISK_ALERT_STATE' "Telegram fails: non-zero, state unchanged"
check '[ $(nbo) -eq 6 ]' "Telegram fails: the backoffice still got the alert"
da 88;  check '[ $(nsent) -eq 6 ] && [ $(nbo) -eq 7 ]' "next run retries the send, on both channels"
echo "warn $(( $(date +%s) - 7*3600 ))" >$DISK_ALERT_STATE; n0=$(nsent)
da 82;  check '[ $(nsent) -eq $n0 ]' "hold band 82% after 7h: no repeat"
echo "crit $(date +%s)" >$DISK_ALERT_STATE
da 83;  check '[ $(nsent) -eq $((n0+1)) ] && grep -q "WARNING: disk at 83% (warns from 85%, clears below 80%)" /tmp/sent' "crit->83%: change announced with true thresholds"
echo 50 >/tmp/used; DISK_WARN_PCT=85% bash /w/scripts/disk-alert.sh >/dev/null 2>&1; check '[ $? -eq 2 ]' "bad threshold -> 2"
check 'grep -q "registry" /tmp/sent' "warning names where to look"

########## the backoffice not taking the alert
reset; BO_RC=3 da 86; rc=$?
check '[ $rc -eq 0 ] && [ $(nsent) -eq 1 ] && ! grep -q "Backoffice" /tmp/sent && grep -Eq "^warn [0-9]+ 0$" $DISK_ALERT_STATE' "backoffice off: Telegram as before, exit 0"

reset; BO_RC=1 da 86; rc=$?
check '[ $rc -eq 1 ] && grep -q "Backoffice not updated: stub failure 1 — alert not sent" /tmp/tg.last' "backoffice refuses: Telegram says so, exit 1"
check 'grep -Eq "^warn [0-9]+ 0$" $DISK_ALERT_STATE' "backoffice refuses: state advances, nothing owed"
check 'grep -q "stub failure 1" /tmp/da.err' "backoffice refuses: reason on stderr"
da 86;  check '[ $(nbo) -eq 1 ] && [ $(nsent) -eq 1 ]' "backoffice refused: not retried"

reset; BO_RC=75 da 86; rc=$?
check '[ $rc -eq 1 ] && grep -q "Backoffice not updated, retried on the next run: stub failure 75" /tmp/tg.last' "backoffice 5xx: Telegram says it will be retried, exit 1"
check 'grep -Eq "^warn [0-9]+ 1$" $DISK_ALERT_STATE' "backoffice 5xx: state advances, backoffice owed"
# Backdated, so a retry that rewrote Telegram's timestamp would show.
t0=$(( $(cut -d" " -f2 $DISK_ALERT_STATE) - 3600 ))
echo "warn $t0 1" >$DISK_ALERT_STATE
BO_RC=75 da 87; rc=$?
check '[ $rc -eq 1 ] && [ $(nbo) -eq 2 ] && [ $(nsent) -eq 1 ] && grep -qx "warn $t0 1" $DISK_ALERT_STATE' "still failing: backoffice alone retried, still owed"
da 87; rc=$?
check '[ $rc -eq 0 ] && [ $(nbo) -eq 3 ] && [ $(nsent) -eq 1 ] && bo 3 | grep -qx "key=disk-root status=firing severity=warning" && bo 3 | grep -q "title=WARNING: disk at 87%"' "backoffice back: gets the current level, Telegram nothing"
check 'grep -qx "warn $t0 0" $DISK_ALERT_STATE' "backoffice back: debt cleared, Telegram's timestamp kept"
da 87;  check '[ $(nbo) -eq 3 ] && [ $(nsent) -eq 1 ]' "caught up: silent"

reset; da 86; BO_RC=75 da 70
check 'bo 2 | grep -q "status=resolved" && grep -Eq "^ok [0-9]+ 1$" $DISK_ALERT_STATE' "lost resolve: owed"
da 70;  check '[ $(nbo) -eq 3 ] && bo 3 | grep -qx "key=disk-root status=resolved severity=" && [ $(nsent) -eq 2 ] && grep -Eq "^ok [0-9]+ 0$" $DISK_ALERT_STATE' "lost resolve: retried alone, then cleared"

reset; BO_RC=75 da 86; BO_RC=1 da 86; rc=$?
check '[ $rc -eq 1 ] && grep -Eq "^warn [0-9]+ 0$" $DISK_ALERT_STATE' "retry refused: debt dropped, not hammered"
da 86;  check '[ $(nbo) -eq 2 ]' "retry refused: no further attempts"

reset; BO_RC=75 da 86; BO_RC=3 da 86; rc=$?
check '[ $rc -eq 0 ] && grep -Eq "^warn [0-9]+ 0$" $DISK_ALERT_STATE' "channel switched off while owed: debt dropped"

reset; echo 86 >/tmp/used; TG_FAIL=1 BO_RC=75 bash /w/scripts/disk-alert.sh >/dev/null 2>&1; rc=$?
check '[ $rc -ne 0 ] && grep -qx "ok 0 1" $DISK_ALERT_STATE' "both fail: Telegram's level kept, backoffice owed"
da 86;  check '[ $(nsent) -eq 1 ] && [ $(nbo) -eq 2 ] && grep -Eq "^warn [0-9]+ 0$" $DISK_ALERT_STATE' "both fail: next run sends both"

reset; echo 86 >/tmp/used; TG_FAIL=1 BO_RC=1 bash /w/scripts/disk-alert.sh >/dev/null 2>&1; rc=$?
check '[ $rc -ne 0 ] && [ ! -e $DISK_ALERT_STATE ]' "Telegram fails, backoffice refuses: nothing owed to it"

########## Telegram fails after the backoffice took a change, then the level goes back
reset; echo 86 >/tmp/used; TG_FAIL=1 bash /w/scripts/disk-alert.sh >/dev/null 2>&1
check 'bo 1 | grep -q "status=firing" && grep -qx "ok 0 1" $DISK_ALERT_STATE' "fired, Telegram failed: the backoffice is marked as ahead"
da 70;  check '[ $(nbo) -eq 2 ] && bo 2 | grep -q "status=resolved" && [ $(nsent) -eq 0 ] && grep -qx "ok 0 0" $DISK_ALERT_STATE' "back to ok: the backoffice alert is resolved, Telegram told nothing"

reset; mkdir -p /tmp/da; echo "warn $(date +%s) 0" >$DISK_ALERT_STATE
t1=$(cut -d" " -f2 $DISK_ALERT_STATE)
echo 70 >/tmp/used; TG_FAIL=1 bash /w/scripts/disk-alert.sh >/dev/null 2>&1
check 'bo 1 | grep -q "status=resolved" && grep -qx "warn $t1 1" $DISK_ALERT_STATE' "resolved, Telegram failed: Telegram's warn kept, backoffice ahead"
da 82;  check '[ $(nbo) -eq 2 ] && bo 2 | grep -qx "key=disk-root status=firing severity=warning" && [ $(nsent) -eq 0 ]' "back in the hold band: the backoffice alert fires again"

reset; mkdir -p /tmp/da; echo "warn $(date +%s) x" >$DISK_ALERT_STATE
da 86;  check '[ $(nbo) -eq 0 ] && [ $(nsent) -eq 0 ]' "unreadable third state field counts as nothing owed"

finish disk-alert
