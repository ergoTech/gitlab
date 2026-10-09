#!/bin/bash
# maintenance.sh with docker, df, journalctl and both notifiers stubbed: the
# escalation order, that the registry is never touched, and what reaches each
# channel.
set -u
. /t/lib.sh || exit 2
stub_world

export MAINTENANCE_LOG=/tmp/m.log MAINTENANCE_LOCK=/tmp/m.lock
run() { # args: used [script args]
    rm -rf /tmp/calls /tmp/sent /tmp/tg.last /tmp/bo.d /tmp/order /tmp/m.log; echo "$1" >/tmp/used; shift
    bash /w/scripts/maintenance.sh "$@" >/tmp/m.out 2>/tmp/m.err; echo $?
}
bo() { cat "/tmp/bo.d/$1"; }
no_registry() { ! grep -q "exec gitlab" /tmp/calls; }

# A: 90 -> escalated prune brings it to 60
rc=$(AFTER_ESC=60 run 90)
check '[ $rc -eq 0 ]' "A: exit 0"
check 'grep -q "until=1h" /tmp/calls && ! grep -q "volume" /tmp/calls' "A: escalated prune enough, no volumes"
check 'no_registry' "A: escalation never touches the registry"
check '[ ! -e /tmp/sent ]' "A: nothing to Telegram"
check '[ $(nbo) -eq 1 ] && bo 1 | grep -qx "key=maintenance status=resolved severity="' "A: clean run resolves the backoffice alert"

# B: escalated prune not enough -> volumes
rc=$(AFTER_ESC=88 AFTER_VOL=70 run 90)
check '[ $rc -eq 0 ]' "B: exit 0"
check '[ $(grep -c "volume rm" /tmp/calls) -eq 2 ] && ! grep -q "volume rm abab\|volume rm prod" /tmp/calls' "B: only the 2 runner cache volumes removed"
check 'grep -q "volume ls -q --filter dangling=true" /tmp/calls' "B: only dangling volumes listed"
check 'no_registry' "B: no registry step between prune and volumes"

# C: nothing helps
rc=$(AFTER_ESC=89 AFTER_VOL=87 run 90)
check '[ $rc -eq 1 ]' "C: exit 1"
check 'grep -q "needs a human" /tmp/m.log && grep -q "needs a human" /tmp/sent && grep -q "Log: /tmp/m.log" /tmp/sent' "C: failure posted to Telegram"
check 'grep -q "finished with failures" /tmp/m.err' "C: stderr line for cron"
check '[ $(nbo) -eq 1 ] && bo 1 | grep -qx "key=maintenance status=firing severity=warning" && bo 1 | grep -qx "title=GitLab maintenance finished with failures"' "C: backoffice alert fired, severity warning"
check 'bo 1 | grep -q "^text=- .*needs a human" && bo 1 | grep -q "^Log: /tmp/m.log$"' "C: backoffice text is the failure list, disk line and log"
check '[ "$(cat /tmp/order)" = "$(printf "bo firing\ntg")" ] && ! grep -q "Backoffice" /tmp/sent' "C: backoffice first, no note when it took the alert"

# D: the flag an old weekly cron entry still passes
rc=$(run 50 --with-registry-gc)
check '[ $rc -eq 0 ] && grep -q -- "--with-registry-gc ignored" /tmp/m.log' "D: legacy flag accepted, logged"
check 'no_registry && [ ! -e /tmp/sent ] && [ ! -s /tmp/m.err ]' "D: legacy flag: no registry calls, no failure"
check 'bo 1 | grep -qx "key=maintenance status=resolved severity="' "D: legacy flag run still resolves"
rc=$(run 50 --bogus)
check '[ $rc -eq 2 ]' "D: unknown argument -> 2"

# G: quiet night
rc=$(run 50)
check '[ $rc -eq 0 ] && no_registry && [ ! -e /tmp/sent ]' "G: quiet night touches no registry, nothing to Telegram"
check '! grep -qi "registry" /tmp/m.log' "G: log never mentions the registry"

# H: Telegram itself fails -> still exit 1, logged, the backoffice still has it
rc=$(AFTER_ESC=89 AFTER_VOL=87 TG_FAIL=1 run 90)
check '[ $rc -eq 1 ] && grep -q "Could not send the failure to Telegram" /tmp/m.log' "H: Telegram failure logged, exit 1"
check 'bo 1 | grep -q "status=firing"' "H: the backoffice got the alert anyway"

# M: the backoffice side
rc=$(AFTER_ESC=89 AFTER_VOL=87 BO_RC=75 run 90)
check '[ $rc -eq 1 ] && grep -q "needs a human" /tmp/sent && grep -q "^Backoffice not updated: stub failure 75 — alert not sent$" /tmp/sent' "M: backoffice fails -> Telegram still sent, with a note"
check 'grep -q "Could not send the failure to the backoffice: stub failure 75" /tmp/m.log' "M: backoffice failure logged"
rc=$(AFTER_ESC=89 AFTER_VOL=87 BO_RC=3 run 90)
check '[ $rc -eq 1 ] && ! grep -q "Backoffice" /tmp/sent && ! grep -qi "backoffice" /tmp/m.log' "M: backoffice off -> no note, nothing logged about it"
rc=$(BO_RC=1 run 50)
check '[ $rc -eq 0 ] && grep -q "Could not resolve the maintenance alert in the backoffice: stub failure 1" /tmp/m.log && [ ! -e /tmp/sent ]' "M: failed resolve on a clean run: logged, exit 0, nothing to Telegram"

# I: --help is the header, and still explains the legacy flag
h=$(bash /w/scripts/maintenance.sh --help)
check 'echo "$h" | grep -q "Run daily via cron" && echo "$h" | grep -q -- "--with-registry-gc, which the weekly" && ! echo "$h" | grep -q "^set "' "I: help is the header only"

finish maintenance
