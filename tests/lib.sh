# Sourced by every tests/test-*.sh. tests/run.sh runs each of them in a fresh
# container with the repo's scripts/ at /s (read-only) and tests/ at /t.
#
# Never anywhere else: the tests overwrite /w and fixed paths in /tmp, put stubs
# in front of docker, and test-notify-backoffice.sh adds a CA of its own to the
# system's trusted certificates.
if [ ! -e /.dockerenv ] && [ ! -e /run/.containerenv ]; then
    echo "run the tests through tests/run.sh (make test): they expect a throwaway container" >&2
    exit 2
fi

pass=0 failc=0
ok()     { pass=$((pass + 1)); [ -z "${VERBOSE:-}" ] || echo "PASS $*"; }
bad()    { failc=$((failc + 1)); echo "FAIL $*"; }
check()  { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
finish() { echo "== $1: $pass passed, $failc failed"; [ "$failc" -eq 0 ]; }

# A copy of scripts/ in /w/scripts with both notifiers replaced by recorders,
# and df, journalctl and docker replaced by stubs in /w/bin, first on PATH.
#   /tmp/used     the usage df reports for /, in percent
#   /tmp/order    one line per notifier call, in call order: "bo <status>" or "tg"
#   /tmp/sent     every Telegram message, each followed by a line "---"
#   /tmp/tg.last  the last Telegram message
#   /tmp/bo.d/N   the Nth backoffice call: key, status, severity; title; text
#   /tmp/calls    every docker call
# TG_FAIL=1 fails the Telegram send. BO_RC is the backoffice's exit code (0 by
# default; 3 channel off, 75 worth retrying, anything else refused).
# For maintenance.sh: AFTER_ESC and AFTER_VOL set the usage the escalated
# prune and the volume removal leave behind. `docker exec` into the gitlab
# container is recorded and answered with nothing: maintenance.sh no longer
# touches the registry, and the tests check that it never does.
stub_world() {
    W=/w
    rm -rf "$W"
    mkdir -p "$W/scripts" "$W/bin"
    cp /s/*.sh "$W/scripts/"

    cat >"$W/scripts/notify-telegram.sh" <<'EOF'
#!/bin/bash
echo tg >>/tmp/order
[ "${TG_FAIL:-}" = 1 ] && { echo "stub telegram failed" >&2; exit 1; }
printf '%s\n---\n' "$1" >>/tmp/sent
printf '%s' "$1" >/tmp/tg.last
EOF
    cat >"$W/scripts/notify-backoffice.sh" <<'EOF'
#!/bin/bash
echo "bo $2" >>/tmp/order
mkdir -p /tmp/bo.d
n=$(( $(ls /tmp/bo.d | wc -l) + 1 ))
printf 'key=%s status=%s severity=%s\ntitle=%s\ntext=%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" >"/tmp/bo.d/$n"
rc=${BO_RC:-0}
case "$rc" in 0|3) ;; *) echo "notify-backoffice: stub failure $rc — alert not sent" >&2 ;; esac
exit "$rc"
EOF
    chmod +x "$W"/scripts/*.sh

    cat >"$W/bin/df" <<'EOF'
#!/bin/bash
u=$(cat /tmp/used)
if [ "$1" = "--output=pcent" ]; then printf ' Use%%\n %s%%\n' "$u"; else printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/sda4 145G 1G 1G %s%% /\n' "$u"; fi
EOF
    cat >"$W/bin/journalctl" <<'EOF'
#!/bin/bash
exit 0
EOF
    # The `ps --format` listing goes out through `env printf` in one write(),
    # as docker's own CLI writes it. bash's builtin printf writes it a line at
    # a time, and a reader under pipefail that matches an early line and exits
    # — `| grep -qx gitlab`, while maintenance.sh still ran the registry GC —
    # leaves the stub to die of SIGPIPE before the next line, under parallel
    # load, now and then.
    cat >"$W/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >>/tmp/calls
setu() { [ -n "${1:-}" ] && echo "$1" >/tmp/used; true; }
case "$1 $2" in
  "ps --format") env printf 'gitlab\ngitlab-runner\n%s' "${PS_EXTRA:-}"; exit 0;;
  "ps -aq"|"ps -a") exit 0;;
  "builder prune") exit 0;;
  "image prune") case "$*" in *until=1h*) setu "${AFTER_ESC:-}";; esac; exit 0;;
  "volume ls") printf '%s\n' runner-0123456789abcdef0123456789abcdef-cache-00000000000000000000000000000001 runner-0123456789abcdef0123456789abcdef-cache-00000000000000000000000000000002-protected abababababababababababababababababababababababababababababababab prod-mongodb-data; exit 0;;
  "volume rm") setu "${AFTER_VOL:-}"; exit 0;;
  "exec gitlab") exit 0;;
esac
echo "unhandled: $*" >&2; exit 0
EOF
    chmod +x "$W"/bin/*
    export PATH="$W/bin:$PATH"
}

# Counts of what the recorders above saw.
nsent() { if [ -f /tmp/sent ]; then grep -c '^---$' /tmp/sent; else echo 0; fi; }
nbo()   { if [ -d /tmp/bo.d ]; then ls /tmp/bo.d | wc -l; else echo 0; fi; }
