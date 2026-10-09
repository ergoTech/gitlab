#!/bin/bash
# maintenance.sh with docker, df, journalctl and both notifiers stubbed: the
# escalation order, the registry around signals, and what reaches each channel.
set -u
. /t/lib.sh || exit 2
stub_world

R=/tmp/reg/v2/repositories
mkreg() { rm -rf /tmp/reg; for i in $(seq 1 12); do d=$R/backend/core/_manifests/tags/$(printf 'a%07x' $i)/current; mkdir -p $d; echo x>$d/link; touch -d "@$(( $(date +%s) - (i+20)*86400 ))" $d/link; done; d=$R/backend/core/_manifests/tags/latest/current; mkdir -p $d; echo x >$d/link; touch -d @0 $d/link; }
ntags() { ls $R/backend/core/_manifests/tags | wc -l; }
export REGISTRY_REPOS=$R MAINTENANCE_LOG=/tmp/m.log MAINTENANCE_LOCK=/tmp/m.lock
run() { # args: used [script args]
    rm -rf /tmp/calls /tmp/sent /tmp/tg.last /tmp/bo.d /tmp/order /tmp/m.log; echo "$1" >/tmp/used; shift; mkreg
    bash /w/scripts/maintenance.sh "$@" >/tmp/m.out 2>/tmp/m.err; echo $?
}
order() { grep -nE "$1" /tmp/calls | head -1 | cut -d: -f1; }
bo() { cat "/tmp/bo.d/$1"; }

# A: weekday, 90 -> escalated prune 88 -> GC -> 60
rc=$(AFTER_ESC=88 AFTER_GC=60 run 90)
check '[ $rc -eq 0 ]' "A: exit 0"
check '[ "$(ntags)" -eq 11 ]' "A: tags pruned during escalation (2 old untagged, latest kept)"
s=$(order "stop registry"); g=$(order "registry-garbage-collect"); check '[ -n "$s" ] && [ -n "$g" ] && [ $s -lt $g ]' "A: stop before GC"
check '! grep -q "volume rm" /tmp/calls' "A: no volume removal when GC sufficed"
check '! grep -q "marking blob\|eligible for deletion" /tmp/m.log && grep -q "mark stage complete" /tmp/m.log && grep -q "blobs deleted" /tmp/m.log' "A: GC noise filtered, summaries kept"
check '[ ! -e /tmp/sent ]' "A: nothing to Telegram"
check '[ $(nbo) -eq 1 ] && bo 1 | grep -qx "key=maintenance status=resolved severity="' "A: clean run resolves the backoffice alert"
check 'grep -q "Untagged 2 sha tag" /tmp/m.log' "A: prune output in log"

# B: GC not enough -> volumes
rc=$(AFTER_ESC=88 AFTER_GC=87 AFTER_VOL=70 run 90)
check '[ $rc -eq 0 ]' "B: exit 0"
check '[ $(grep -c "volume rm" /tmp/calls) -eq 2 ] && ! grep -q "volume rm abab\|volume rm prod" /tmp/calls' "B: only the 2 runner cache volumes removed"
check 'grep -q "volume ls -q --filter dangling=true" /tmp/calls' "B: only dangling volumes listed"

# C: nothing helps
rc=$(AFTER_ESC=89 AFTER_GC=88 AFTER_VOL=87 run 90)
check '[ $rc -eq 1 ]' "C: exit 1"
check 'grep -q "needs a human" /tmp/m.log && grep -q "needs a human" /tmp/sent && grep -q "Log: /tmp/m.log" /tmp/sent' "C: failure posted to Telegram"
check 'grep -q "finished with failures" /tmp/m.err' "C: stderr line for cron"
check '[ $(nbo) -eq 1 ] && bo 1 | grep -qx "key=maintenance status=firing severity=warning" && bo 1 | grep -qx "title=GitLab maintenance finished with failures"' "C: backoffice alert fired, severity warning"
check 'bo 1 | grep -q "^text=- .*needs a human" && bo 1 | grep -q "^Log: /tmp/m.log$"' "C: backoffice text is the failure list, disk line and log"
check '[ "$(cat /tmp/order)" = "$(printf "bo firing\ntg")" ] && ! grep -q "Backoffice" /tmp/sent' "C: backoffice first, no note when it took the alert"

# D: Sunday at 90 -> GC exactly once
rc=$(AFTER_ESC=88 AFTER_GC=86 AFTER_VOL=60 run 90 --with-registry-gc)
check '[ $(grep -c registry-garbage-collect /tmp/calls) -eq 1 ]' "D: GC runs once on Sunday escalation"
check 'grep -q "volume rm" /tmp/calls' "D: goes straight to volumes"

# E: GC fails, rc captured through the filter
rc=$(GC_RC=1 run 50 --with-registry-gc)
check '[ $rc -eq 1 ] && grep -q "Registry GC FAILED" /tmp/m.log' "E: GC failure detected through grep filter"
check 'grep -q "Registry GC FAILED" /tmp/sent && bo 1 | grep -q "Registry GC FAILED"' "E: GC failure on both channels"

# F: stop fails -> no pruning, GC still runs
rc=$(STOP_FAIL=1 run 50 --with-registry-gc)
check '[ $rc -eq 1 ] && [ "$(ntags)" -eq 13 ] && grep -q registry-garbage-collect /tmp/calls' "F: stop failure skips prune, GC runs"

# G: quiet weekday
rc=$(run 50)
check '[ $rc -eq 0 ] && ! grep -v "gitlab-ctl status registry" /tmp/calls | grep -q "registry" && [ ! -e /tmp/sent ]' "G: quiet weekday touches no registry beyond asking its status, nothing to Telegram"

# H: Telegram itself fails -> still exit 1, logged, the backoffice still has it
rc=$(AFTER_ESC=89 AFTER_GC=88 AFTER_VOL=87 TG_FAIL=1 run 90)
check '[ $rc -eq 1 ] && grep -q "Could not send the failure to Telegram" /tmp/m.log' "H: Telegram failure logged, exit 1"
check 'bo 1 | grep -q "status=firing"' "H: the backoffice got the alert anyway"

# M: the backoffice side
rc=$(REG_DOWN=1 run 50 --with-registry-gc)
check '[ $rc -eq 1 ] && grep -q "Could not restart the registry" /tmp/m.log && bo 1 | grep -qx "key=maintenance status=firing severity=critical"' "M: registry left down -> critical"
rc=$(REG_DOWN=1 run 50)
check '[ $rc -eq 0 ] && [ $(nbo) -eq 0 ] && grep -q "maintenance alert in the backoffice stays open" /tmp/m.log' "M: clean weekday with the registry still down: no resolve"
rm -f /tmp/reg-started; rc=$(REG_DOWN=2 run 50 --with-registry-gc)
check '[ $rc -eq 1 ] && grep -q "Registry restarted" /tmp/m.log && bo 1 | grep -qx "key=maintenance status=firing severity=warning"' "M: registry down after GC but restarted -> warning"
rc=$(AFTER_ESC=89 AFTER_GC=88 AFTER_VOL=87 BO_RC=75 run 90)
check '[ $rc -eq 1 ] && grep -q "needs a human" /tmp/sent && grep -q "^Backoffice not updated: stub failure 75 — alert not sent$" /tmp/sent' "M: backoffice fails -> Telegram still sent, with a note"
check 'grep -q "Could not send the failure to the backoffice: stub failure 75" /tmp/m.log' "M: backoffice failure logged"
rc=$(AFTER_ESC=89 AFTER_GC=88 AFTER_VOL=87 BO_RC=3 run 90)
check '[ $rc -eq 1 ] && ! grep -q "Backoffice" /tmp/sent && ! grep -qi "backoffice" /tmp/m.log' "M: backoffice off -> no note, nothing logged about it"
rc=$(BO_RC=1 run 50)
check '[ $rc -eq 0 ] && grep -q "Could not resolve the maintenance alert in the backoffice: stub failure 1" /tmp/m.log && [ ! -e /tmp/sent ]' "M: failed resolve on a clean run: logged, exit 0, nothing to Telegram"

# J: SIGTERM while pruning with the registry stopped -> trap starts it, no GC
rm -f /tmp/calls /tmp/m.log; echo 50 >/tmp/used; mkreg
cp /w/scripts/registry-prune-tags.sh /tmp/prune.bak
printf '#!/bin/bash\nsleep 5\n' >/w/scripts/registry-prune-tags.sh
setsid bash /w/scripts/maintenance.sh --with-registry-gc >/dev/null 2>&1 &
bgpid=$!; sleep 1.5; kill -TERM -- -$bgpid 2>/dev/null; wait $bgpid; rc=$?; sleep 1
cp /tmp/prune.bak /w/scripts/registry-prune-tags.sh
check 'grep -q "gitlab-ctl start registry" /tmp/calls && ! grep -q registry-garbage-collect /tmp/calls' "J: trap restarts registry, GC not run"
check '[ $rc -ne 0 ]' "J: non-zero exit after signal"

# K: after GC starts, the trap is cleared (no start from our side on a later signal)
rm -f /tmp/calls; echo 50 >/tmp/used; mkreg
run 50 --with-registry-gc >/dev/null
check '[ $(grep -c "gitlab-ctl start registry" /tmp/calls) -eq 0 ]' "K: normal run never starts registry itself"

# L: reader of stdout quits mid-prune (ssh without pty dropped) -> SIGPIPE caught by trap
rm -f /tmp/calls /tmp/m.log; echo 50 >/tmp/used; mkreg
cp /w/scripts/registry-prune-tags.sh /tmp/prune.bak
printf '#!/bin/bash\necho line1\nsleep 1\necho final\n' >/w/scripts/registry-prune-tags.sh
bash /w/scripts/maintenance.sh --with-registry-gc 2>/dev/null | sed '/Untagging/q' >/dev/null; sleep 2
cp /tmp/prune.bak /w/scripts/registry-prune-tags.sh
check 'grep -q "stop registry" /tmp/calls && grep -q "gitlab-ctl start registry" /tmp/calls && ! grep -q registry-garbage-collect /tmp/calls' "L: SIGPIPE mid-prune restarts registry, no GC"

# I: --help still documents both flags
bash /w/scripts/maintenance.sh --help | grep -q -- "--with-registry-gc"; check '[ $? -eq 0 ]' "I: help intact"

finish maintenance
