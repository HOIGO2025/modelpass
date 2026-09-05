#!/usr/bin/env bash
# The single place an alert leaves this machine.
#
#   notify.sh LEVEL "message"        LEVEL: ALERT | WARN | INFO
#   echo "body" | notify.sh LEVEL -  read the body from stdin
#
# Configure ONE (or more) of these in .env. All are reachable from the
# collection host; pick the one you will actually read at 3am. If you are
# behind the GFW, note that the server sending to Telegram does not help if
# you need a VPN to open it -- Feishu / DingTalk / WeCom / Bark do not.
#
#   TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID   @BotFather, then /start the bot
#   FEISHU_WEBHOOK      飞书 group bot webhook URL
#   DINGTALK_WEBHOOK    钉钉 group bot webhook URL
#   WECOM_WEBHOOK       企业微信 group bot webhook URL
#   BARK_URL            https://api.day.app/<your-key>   (iOS push)
#   SMTP_HOST + SMTP_USER + SMTP_PASS + ALERT_EMAIL
#                       email via any SMTP relay; no MTA needed on this host,
#                       and no VPN needed to read it
#
# Unconfigured it is a silent no-op. It never fails: callers have already
# written a marker file, and a broken notifier must not turn a good day into
# a failed one.
set -uo pipefail
cd "$(dirname "$0")/.."

LEVEL="${1:-INFO}"
BODY="${2:-}"
[ "${BODY}" = "-" ] && BODY="$(cat)"
[ -n "${BODY}" ] || exit 0

if [ -f .env ]; then
    set -a; . ./.env; set +a
fi

case "${LEVEL}" in
    ALERT) ICON="🔴" ;;
    WARN)  ICON="🟡" ;;
    *)     ICON="🔵" ;;
esac
TITLE="${ICON} ModelPass ${LEVEL}"
TEXT="$(printf '%s\n\n%s' "${TITLE}" "${BODY}" | head -c 3900)"

sent=0
post_json() {   # post_json <url> <json>   -- returns 0 on 2xx
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -H 'Content-Type: application/json' -d "$2" "$1" 2>/dev/null || echo 000)"
    case "${code}" in 2??) return 0 ;; *) echo "notify.sh: ${3:-webhook} HTTP ${code}" >&2; return 1 ;; esac
}
json_str() {    # JSON-encode stdin as a string literal
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

PAYLOAD_TEXT="$(printf '%s' "${TEXT}" | json_str)"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    # Token stays in the URL and is never echoed.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${TEXT}" \
        --data-urlencode "disable_web_page_preview=true" 2>/dev/null || echo 000)"
    if [ "${code}" = "200" ]; then sent=1; else echo "notify.sh: telegram HTTP ${code}" >&2; fi
fi

if [ -n "${FEISHU_WEBHOOK:-}" ]; then
    post_json "${FEISHU_WEBHOOK}" \
        "{\"msg_type\":\"text\",\"content\":{\"text\":${PAYLOAD_TEXT}}}" feishu && sent=1
fi

if [ -n "${DINGTALK_WEBHOOK:-}" ]; then
    post_json "${DINGTALK_WEBHOOK}" \
        "{\"msgtype\":\"text\",\"text\":{\"content\":${PAYLOAD_TEXT}}}" dingtalk && sent=1
fi

if [ -n "${WECOM_WEBHOOK:-}" ]; then
    post_json "${WECOM_WEBHOOK}" \
        "{\"msgtype\":\"text\",\"text\":{\"content\":${PAYLOAD_TEXT}}}" wecom && sent=1
fi

if [ -n "${BARK_URL:-}" ]; then
    post_json "${BARK_URL%/}" \
        "{\"title\":$(printf '%s' "${TITLE}" | json_str),\"body\":${PAYLOAD_TEXT},\"group\":\"ModelPass\"}" bark && sent=1
fi

if [ -n "${SMTP_HOST:-}" ] && [ -n "${ALERT_EMAIL:-}" ]; then
    if printf '%s\n' "${BODY}" | python3 scripts/send_email.py "[ModelPass] ${LEVEL} ${TITLE_DATE:-}"; then
        sent=1
    fi
elif [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "${BODY}" | mail -s "[ModelPass] ${LEVEL}" "${ALERT_EMAIL}" && sent=1
fi

[ "${sent}" -eq 1 ] || echo "notify.sh: no channel configured; ${LEVEL} logged to file only" >&2
exit 0
