#!/bin/bash
# Send one alert to the backoffice's ops-alert intake, alongside the Telegram
# message (notify-telegram.sh). Telegram is what reaches a person; the
# backoffice keeps the alert on record, open until it is resolved.
#
# The intake is the backend's POST /webhooks/ops-alerts (core's
# docs/api/ops-alerts.md has the contract). It holds one open alert per source
# and key: firing again updates that alert, resolved closes it, and resolving
# one that is not open is accepted and changes nothing.
#
# Configuration is two files under the gitignored data/ directory:
#   data/alerts/backoffice_url    the full intake URL, https only
#   data/alerts/backoffice_token  the backend's OPS_ALERTS_TOKEN, chmod 600
# NOTIFY_SECRETS_DIR overrides the directory. Without backoffice_url the
# channel is off: exit 3, nothing sent and nothing printed, because this repo
# also runs where no backoffice exists.
#
# The token goes to curl on stdin (-K -), not on its command line, where any
# local user could read it from the process list.
#
# Usage:
#   ./scripts/notify-backoffice.sh <key> firing <info|warning|critical> <title> [text]
#   ./scripts/notify-backoffice.sh <key> resolved
# Exit codes:
#    0  accepted
#    1  not sent, and sending the same again will not help (configuration, 3xx, 4xx)
#    2  usage error
#    3  channel off: no backoffice_url
#   75  not sent, worth retrying (no answer, timeout, 408, 429, 5xx)

set -euo pipefail

# Strings are handled by character, not byte — lengths, patterns and the cuts
# below — for the same reason as in notify-telegram.sh.
LC_ALL=C.UTF-8

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NOTIFY_SECRETS_DIR="${NOTIFY_SECRETS_DIR:-$SCRIPT_DIR/../data/alerts}"
OPS_ALERT_SOURCE="${OPS_ALERT_SOURCE:-gitlab-host}"
BACKOFFICE_TIMEOUT="${BACKOFFICE_TIMEOUT:-15}"

usage() {
    echo "usage: $0 <key> firing <info|warning|critical> <title> [text]" >&2
    echo "       $0 <key> resolved" >&2
    exit 2
}

# The intake's own patterns, checked here so that a typo fails as a usage
# error on the spot instead of as a 400 in a log nobody reads.
key_re='^[a-z0-9._-]{1,128}$'
source_re='^[a-z0-9._-]{1,64}$'
key=${1:-}
status=${2:-}
[[ $key =~ $key_re ]] || usage
if [[ ! $OPS_ALERT_SOURCE =~ $source_re ]]; then
    echo "OPS_ALERT_SOURCE must match [a-z0-9._-]{1,64}, got '$OPS_ALERT_SOURCE'" >&2
    exit 2
fi
# Compared as a number, so that 00 is refused like 0: curl reads either as no
# time limit at all, and a backend that never answers would then hold the
# Telegram message back for good.
case "$BACKOFFICE_TIMEOUT" in
    ''|*[!0-9]*|????*) timeout_ok=false ;;
    *) [ "$((10#$BACKOFFICE_TIMEOUT))" -ge 1 ] && timeout_ok=true || timeout_ok=false ;;
esac
if [ "$timeout_ok" = false ]; then
    echo "BACKOFFICE_TIMEOUT must be a whole number of seconds from 1 to 999, got '$BACKOFFICE_TIMEOUT'" >&2
    exit 2
fi
case "$status" in
    firing)
        [ $# -ge 4 ] && [ $# -le 5 ] || usage
        severity=$3 title=$4 text=${5:-}
        case "$severity" in info|warning|critical) ;; *) usage ;; esac
        # The intake trims a title and refuses it empty; the control
        # characters json_str drops below would leave it empty too.
        [[ $title == *[![:space:][:cntrl:]]* ]] || usage
        ;;
    resolved)
        [ $# -eq 2 ] || usage
        ;;
    *) usage ;;
esac

url_file="$NOTIFY_SECRETS_DIR/backoffice_url"
token_file="$NOTIFY_SECRETS_DIR/backoffice_token"
# data/alerts is root's and 700: run as anyone else, every file in it looks
# absent, and a channel that is configured would pass for one that is off.
if [ -d "$NOTIFY_SECRETS_DIR" ] && [ ! -x "$NOTIFY_SECRETS_DIR" ]; then
    echo "notify-backoffice: cannot look into $NOTIFY_SECRETS_DIR (run it as root) — alert not sent" >&2
    exit 1
fi
[ -e "$url_file" ] || exit 3
for f in "$url_file" "$token_file"; do
    if [ ! -r "$f" ]; then
        echo "notify-backoffice: cannot read $f — alert not sent" >&2
        exit 1
    fi
done

# Neither file's content is ever printed: a token pasted into the wrong file
# would otherwise end up in the message that reports the mistake.
url=$(tr -d '[:space:]' <"$url_file")
if [[ ! $url =~ ^https://[^/]+ ]]; then
    echo "notify-backoffice: $url_file does not hold an https:// URL — alert not sent" >&2
    exit 1
fi
token=$(tr -d '[:space:]' <"$token_file")
# The backend will not run the intake with a token under 32 characters, so a
# shorter one here cannot be the right one. The character set is what a
# quoted curl config line takes without escaping.
token_re='^[A-Za-z0-9._~+/=-]+$'
if [ "${#token}" -lt 32 ] || [[ ! $token =~ $token_re ]]; then
    echo "notify-backoffice: $token_file does not hold a usable OPS_ALERTS_TOKEN (32+ characters of A-Z a-z 0-9 . _ ~ + / = -) — alert not sent" >&2
    exit 1
fi

# A JSON string: what JSON requires escaped is escaped, and the remaining
# control characters are dropped. tr works on bytes, and no byte of a
# multibyte UTF-8 character falls in that range, so it cannot split one.
json_str() {
    local s
    s=$(printf '%s' "$1" | tr -d '\001-\010\013\014\016-\037')
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

# The intake cuts a title at 200 characters and a text at 4000, ending the cut
# with "…", but refuses a body over 64 KiB whole. Cutting here the same way
# keeps the body far under that limit whatever a caller passes.
clip() {
    if [ "${#1}" -gt "$2" ]; then
        printf '%s…' "${1:0:$(($2 - 1))}"
    else
        printf '%s' "$1"
    fi
}
body="{\"source\":$(json_str "$OPS_ALERT_SOURCE"),\"key\":$(json_str "$key"),\"status\":\"$status\""
if [ "$status" = firing ]; then
    body+=",\"severity\":\"$severity\",\"title\":$(json_str "$(clip "$title" 200)")"
    if [ -n "$text" ]; then
        body+=",\"text\":$(json_str "$(clip "$text" 4000)")"
    fi
fi
body+=",\"occurred_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

# The HTTP status decides, not curl's exit code: without -f curl exits 0 on
# any answer, and -f would still pass a 3xx — a redirect that delivers nothing.
# Redirects are not followed (no -L): the intake answers directly or not at all.
# -q, which only works first, keeps a ~/.curlrc from turning -L or -k back on.
# -s without -S: a failure's message comes back through %{errormsg} instead.
resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -q -s --proto =https --max-time "$BACKOFFICE_TIMEOUT" -K - \
        -H 'Content-Type: application/json' \
        --data-binary "$body" \
        -w '\n%{http_code} %{errormsg}' \
        "$url") || true
last=${resp##*$'\n'}
code=${last%% *}
case "$code" in
    2??) exit 0 ;;
esac

answer=${resp%$'\n'*}
retry=false
case "$code" in
    000|'')  why="no answer from the intake: ${last#* }"; retry=true ;;
    401)     why="HTTP 401: the token is not the backend's OPS_ALERTS_TOKEN" ;;
    404)     why="HTTP 404: wrong URL, or the intake is off on the backend (OPS_ALERTS_TOKEN missing there or under 32 characters)" ;;
    413)     why="HTTP 413: the body is over the intake's limit" ;;
    3??)     why="HTTP $code: the intake URL redirects; put the final address in $url_file" ;;
    408|429|5??) why="HTTP $code from the intake"; retry=true ;;
    *)       why="HTTP $code from the intake" ;;
esac
# The intake answers errors in JSON; a proxy's HTML error page would only be noise.
if [[ $answer == '{'* ]]; then
    answer=${answer//$'\n'/ }
    why+=": ${answer:0:200}"
fi
echo "notify-backoffice: $why — alert not sent" >&2
if [ "$retry" = true ]; then
    exit 75
fi
exit 1
