#!/usr/bin/env bash
# The single place an alert leaves this machine.
#
#   notify.sh LEVEL "message"        LEVEL: ALERT | WARN | INFO
#   echo "body" | notify.sh LEVEL -  read the body from stdin
#
# Configure in .env:
#   TELEGRAM_BOT_TOKEN   from @BotFather
#   TELEGRAM_CHAT_ID     your user or group id
#
# Silent no-op when unconfigured -- callers have already written a marker
# file, so nothing is lost if this channel is missing. Never fails the run:
# a broken notifier must not turn a good day into a failed one.
set -uo pipefail
cd "$(dirname "$0")/.."

LEVEL="${1:-INFO}"
BODY="${2:-}"
[ "${BODY}" = "-" ] && BODY="$(cat)"

if [ -f .env ]; then
    set -a; . ./.env; set +a
fi

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

[ -n "${BODY}" ] || exit 0

case "${LEVEL}" in
    ALERT) ICON="🔴" ;;
    WARN)  ICON="🟡" ;;
    *)     ICON="🔵" ;;
esac

sent=0

if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
    # Telegram caps a message at 4096 characters.
    TEXT="$(printf '%s ModelPass %s\n\n%s' "${ICON}" "${LEVEL}" "${BODY}" | head -c 3900)"
    # --data-urlencode keeps newlines and any characters intact; the token
    # stays in the URL and is never echoed.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${TEXT}" \
        --data-urlencode "disable_web_page_preview=true" 2>/dev/null || echo 000)"
    if [ "${code}" = "200" ]; then
        sent=1
    else
        echo "notify.sh: telegram send failed (HTTP ${code})" >&2
    fi
fi

if [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "${BODY}" | mail -s "[ModelPass] ${LEVEL}" "${ALERT_EMAIL}" && sent=1
fi

[ "${sent}" -eq 1 ] || echo "notify.sh: no channel configured; ${LEVEL} logged to file only" >&2
exit 0
