#!/bin/bash
# Send one plain-text message to the ops Telegram chat.
#
# Why Telegram and not cron mail: this host has no MTA. `MAILTO=root` in
# /etc/cron.d/gitlab-maintenance delivers nowhere, so "Disk STILL at 87% after
# escalation — needs a human" sat in the log for three nights in a row
# (2026-10-06..08) and the first anyone heard of the disk was a failed deploy.
#
# Credentials are two files, chmod 600, under the gitignored data/ directory —
# the same bot and chat production's Alertmanager uses:
#   data/alerts/bot_token
#   data/alerts/chat_id
# NOTIFY_SECRETS_DIR overrides the directory.
#
# The token goes to curl on stdin (-K -), not on its command line, where any
# local user could read it from the process list.
#
# Usage: ./scripts/notify-telegram.sh "message text"
# Exit code is non-zero if the message was not sent.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NOTIFY_SECRETS_DIR="${NOTIFY_SECRETS_DIR:-$SCRIPT_DIR/../data/alerts}"

if [ $# -eq 0 ] || [ -z "$1" ]; then
    echo "usage: $0 \"message\"" >&2
    exit 2
fi

token_file="$NOTIFY_SECRETS_DIR/bot_token"
chat_file="$NOTIFY_SECRETS_DIR/chat_id"
if [ ! -r "$token_file" ] || [ ! -r "$chat_file" ]; then
    echo "notify-telegram: no credentials in $NOTIFY_SECRETS_DIR (bot_token, chat_id) — message not sent" >&2
    exit 1
fi

token=$(tr -d '[:space:]' <"$token_file")
chat=$(tr -d '[:space:]' <"$chat_file")
if [ -z "$token" ] || [ -z "$chat" ]; then
    echo "notify-telegram: empty bot_token or chat_id in $NOTIFY_SECRETS_DIR — message not sent" >&2
    exit 1
fi

# Telegram rejects messages over 4096 characters outright. Cut by character,
# not byte: under a C/POSIX locale (LANG unset) bash slices bytes, and a cut
# through a "—" leaves invalid UTF-8, which Telegram rejects too. Cron here
# does get LANG from /etc/default/locale; this does not depend on that.
LC_ALL=C.UTF-8
text="[$(hostname)] $1"
text=${text:0:4000}

printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" |
    curl -fsS --max-time 20 -K - \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=${text}" \
        -o /dev/null
