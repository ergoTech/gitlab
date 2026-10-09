#!/bin/bash
# notify-backoffice.sh with the real curl against a local HTTPS stand-in for
# the intake (intake-stub.py): what reaches the server, and what each answer
# turns into as an exit code.
set -u
. /t/lib.sh || exit 2

SRV=$(mktemp -d)   # the stub's certificates and recorded requests
D=$(mktemp -d)     # NOTIFY_SECRETS_DIR, root's and 700 like data/alerts
export NOTIFY_SECRETS_DIR=$D

# A throwaway CA in the system trust store and a certificate for localhost, so
# curl verifies the stub exactly as it would the real intake — no -k anywhere.
(
    cd "$SRV" || exit 1
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test-ca -keyout ca.key -out ca.crt
    openssl req -newkey rsa:2048 -nodes -subj /CN=localhost -keyout srv.key -out srv.csr
    printf 'subjectAltName=DNS:localhost\n' >ext
    openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile ext -out srv.crt
    cp ca.crt /usr/local/share/ca-certificates/test-ca.crt
    update-ca-certificates
) >/dev/null 2>&1
python3 /t/intake-stub.py "$SRV" 8443 "$SRV/srv.crt" "$SRV/srv.key" &
stub=$!
for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null && break; sleep 0.1; done

URL=https://localhost:8443/webhooks/ops-alerts
TOKEN=$(openssl rand -hex 32)
cfg() { printf '%s\n' "$1" >"$D/backoffice_url"; printf '%s\n' "$2" >"$D/backoffice_token"; }
respond() { printf '%s\n%s' "$1" "${2:-}" >"$SRV/respond"; }
nreq() { ls "$SRV" | grep -c '^req\..*\.json$'; }
q() { python3 /t/req.py "$SRV" last "$@"; }
# Every word the script prints goes to /tmp/printed, which must never hold a token.
send() { bash /s/notify-backoffice.sh "$@" >/tmp/out 2>/tmp/err; local rc=$?; cat /tmp/out /tmp/err >>/tmp/printed; return $rc; }

########## off and misconfigured: nothing is sent
send disk-root resolved; rc=$?
check '[ $rc -eq 3 ] && [ ! -s /tmp/out ] && [ ! -s /tmp/err ] && [ $(nreq) -eq 0 ]' "no backoffice_url: off, exit 3, silent"

printf '%s\n' "$URL" >"$D/backoffice_url"
send disk-root resolved; rc=$?
check '[ $rc -eq 1 ] && grep -q "cannot read $D/backoffice_token" /tmp/err' "URL without a token file: exit 1"
cfg "$URL" "0123456789abcdef"
send disk-root resolved; rc=$?
check '[ $rc -eq 1 ] && grep -q "usable OPS_ALERTS_TOKEN" /tmp/err' "token under 32 characters: exit 1"
BADTOKEN="0123456789abcdef0123456789abcdef\"x"
cfg "$URL" "$BADTOKEN"
send disk-root resolved; rc=$?
check '[ $rc -eq 1 ] && ! grep -qF "$BADTOKEN" /tmp/printed' "token with a quote: exit 1, not printed"
cfg "http://localhost:8443/webhooks/ops-alerts" "$TOKEN"
send disk-root resolved; rc=$?
check '[ $rc -eq 1 ] && grep -q "https://" /tmp/err' "http URL: exit 1"
cfg "$TOKEN" "$TOKEN"
send disk-root resolved; rc=$?
check '[ $rc -eq 1 ]' "token pasted into the URL file: exit 1"
cfg "$URL" "$TOKEN"
su nobody -s /bin/bash -c "NOTIFY_SECRETS_DIR=$D bash /s/notify-backoffice.sh disk-root resolved" >/tmp/out 2>/tmp/err; rc=$?
check '[ $rc -eq 1 ] && grep -q "cannot look into $D" /tmp/err' "secrets dir unreadable to the caller: exit 1, not taken for off"
check '[ $(nreq) -eq 0 ]' "none of the above reached the intake"

########## usage
for args in "disk-root" "disk-root firing" "disk-root firing urgent t" "Disk-Root resolved" \
            "disk-root resolved extra" "disk-root bogus" "disk/root resolved"; do
    # shellcheck disable=SC2086
    send $args; rc=$?
    check '[ $rc -eq 2 ]' "usage error: '$args' -> 2"
done
send disk-root firing warning ""; check '[ $? -eq 2 ]' "usage error: empty title -> 2"
OPS_ALERT_SOURCE="bad source" send disk-root resolved; check '[ $? -eq 2 ]' "bad OPS_ALERT_SOURCE -> 2"
BACKOFFICE_TIMEOUT=10s send disk-root resolved; check '[ $? -eq 2 ]' "bad BACKOFFICE_TIMEOUT -> 2"
BACKOFFICE_TIMEOUT=00 send disk-root resolved; check '[ $? -eq 2 ]' "BACKOFFICE_TIMEOUT 00, which curl reads as no limit -> 2"
send disk-root firing warning "   "; check '[ $? -eq 2 ]' "blank title -> 2"
send disk-root firing warning $'\001\n'; check '[ $? -eq 2 ]' "title of control characters only -> 2"
check '[ $(nreq) -eq 0 ]' "no usage error reached the intake"

########## what arrives
rm -f "$SRV/respond"
send disk-root firing warning "WARNING: disk at 86%" "line one
line two"; rc=$?
check '[ $rc -eq 0 ] && [ ! -s /tmp/out ] && [ ! -s /tmp/err ]' "202: exit 0, silent"
check '[ "$(q method)" = POST ] && [ "$(q path)" = /webhooks/ops-alerts ]' "POST to the URL as given"
check '[ "$(q header authorization)" = "Bearer $TOKEN" ]' "token in the Authorization header"
check '[ "$(q header content-type)" = application/json ]' "JSON content type"
check '[ "$(q keys)" = "key,occurred_at,severity,source,status,text,title" ]' "firing: exactly the contract's fields"
check '[ "$(q field source)" = gitlab-host ] && [ "$(q field key)" = disk-root ] && [ "$(q field status)" = firing ] && [ "$(q field severity)" = warning ]' "firing: source, key, status, severity"
check '[ "$(q field title)" = "WARNING: disk at 86%" ] && [ "$(q field text)" = "$(printf "line one\nline two")" ]' "firing: title and text intact"
check '[[ $(q field occurred_at) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]' "occurred_at is RFC 3339 UTC"
send disk-root firing info "no text"; check '[ $? -eq 0 ] && [ "$(q keys)" = "key,occurred_at,severity,source,status,title" ]' "firing without text: no text field"

respond 202 '{"id":null}'
send disk-root resolved; rc=$?
check '[ $rc -eq 0 ] && [ "$(q keys)" = "key,occurred_at,source,status" ] && [ "$(q field status)" = resolved ]' "resolved, nothing open (id null): exit 0, only its four fields"
rm -f "$SRV/respond"

OPS_ALERT_SOURCE=other-host.1 send disk-root resolved; check '[ $? -eq 0 ] && [ "$(q field source)" = other-host.1 ]' "OPS_ALERT_SOURCE overrides the source"

title='quote " backslash \ and a tab	here'
text=$'cr\r lf\n ctl\001\037 gone — Диск 90%'
send disk-root firing critical "$title" "$text"; rc=$?
check '[ $rc -eq 0 ] && [ "$(q field title)" = "$title" ]' "quote, backslash and tab survive in the title"
check '[ "$(q field text)" = "$(printf "cr\r lf\n ctl gone — Диск 90%%")" ]' "CR and LF survive, other control characters dropped, UTF-8 intact"

long_title=$(printf 'й%.0s' $(seq 1 300))
long_text=$(printf '—%.0s' $(seq 1 5000))
send disk-root firing warning "$long_title" "$long_text"; rc=$?
check '[ $rc -eq 0 ] && [ "$(q len title)" -eq 200 ] && [ "$(q len text)" -eq 4000 ]' "cut to 200 / 4000 characters, not bytes, into valid UTF-8"
check '[[ $(q field title) == *й… ]] && [[ $(q field text) == *——… ]]' "a cut ends in …, as the intake's own does"

########## answers
check_answer() { # status body expected-rc expected-stderr-fragment description
    local want_rc=$3 want_err=$4 n0 rc
    respond "$1" "$2"
    n0=$(nreq)
    send disk-root firing warning "t" "x"; rc=$?
    check '[ $rc -eq $want_rc ] && { [ -z "$want_err" ] || grep -qF -- "$want_err" /tmp/err; } && [ $(nreq) -eq $((n0 + 1)) ]' "$5"
}
check_answer 400 '{"error":"title is required","code":"validation_failed"}' 1 "validation_failed" "400: exit 1, the intake's reason shown"
check_answer 401 '' 1 "not the backend's OPS_ALERTS_TOKEN" "401: exit 1, names the token"
check_answer 404 '' 1 "intake is off on the backend" "404: exit 1, names both causes"
check_answer 413 '' 1 "413" "413: exit 1"
check_answer 403 '<html><body>blocked by a proxy</body></html>' 1 "HTTP 403" "403 with an HTML page: exit 1"
check '! grep -q "<html" /tmp/err' "403: the HTML page is not echoed"
check_answer 301 '' 1 "redirects" "301: exit 1, and the redirect is not followed"
check_answer 302 '' 1 "redirects" "302: exit 1"
check_answer 500 '' 75 "HTTP 500" "500: worth retrying, 75"
check_answer 502 '' 75 "HTTP 502" "502: worth retrying, 75"
check_answer 503 '' 75 "HTTP 503" "503: worth retrying, 75"
check_answer 429 '' 75 "HTTP 429" "429: worth retrying, 75"
check_answer 408 '' 75 "HTTP 408" "408: worth retrying, 75"
check_answer 204 '' 0 "" "204: any 2xx is taken"
rm -f "$SRV/respond"

########## no answer
cfg "https://localhost:8444/webhooks/ops-alerts" "$TOKEN"
send disk-root resolved; rc=$?
check '[ $rc -eq 75 ] && grep -q "no answer from the intake" /tmp/err' "nothing listening: 75"
cfg "https://127.0.0.1:8443/webhooks/ops-alerts" "$TOKEN"
n0=$(nreq); send disk-root resolved; rc=$?
check '[ $rc -eq 75 ] && [ $(nreq) -eq $n0 ]' "certificate for another name: refused before any request, 75"
cfg "$URL" "$TOKEN"
respond "202 3"
BACKOFFICE_TIMEOUT=1 send disk-root resolved; rc=$?
check '[ $rc -eq 75 ] && grep -q "timed out" /tmp/err' "slower than BACKOFFICE_TIMEOUT: 75"
rm -f "$SRV/respond"

########## the token stays off every command line
# The scan's control: a token on a command line is found. Two commands, so
# bash stays the process instead of exec'ing sleep, which has no token in its
# arguments.
bash -c 'sleep 3; :' "$TOKEN" &
ctl=$!
sleep 0.3
scan() { local f; for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' <"$f" 2>/dev/null; echo; done; }
check 'scan | grep -qF "$TOKEN"' "control: the scan finds a token on a command line"
kill "$ctl" 2>/dev/null; wait "$ctl" 2>/dev/null
respond "202 2"
bash /s/notify-backoffice.sh disk-root firing warning "t" "x" >/dev/null 2>&1 &
pid=$!; sleep 0.7
seen=$(scan)
wait $pid; rc=$?
check 'grep -q "^curl " <<<"$seen"' "curl was in flight during the scan"
check '! grep -qF "$TOKEN" <<<"$seen" && [ $rc -eq 0 ]' "token on no command line while the request is in flight"
rm -f "$SRV/respond"

check '! grep -qF "$TOKEN" /tmp/printed' "the token never appears in anything the script printed"

kill "$stub" 2>/dev/null
finish notify-backoffice
