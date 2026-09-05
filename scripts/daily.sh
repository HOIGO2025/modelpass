#!/usr/bin/env bash
# Cron entry point.  The single most important line in this project is the
# crontab line that calls this file:
#
#   0 3 * * * /opt/modelpass/scripts/daily.sh
#
# Everything else can be rewritten later.  A day not collected is gone.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Host runs use the venv; the container installs deps system-wide.
if [ -f .venv/bin/activate ]; then
    # shellcheck disable=SC1091
    source .venv/bin/activate
fi

if [ -f .env ]; then
    set -a; . ./.env; set +a
fi
ALERT_EMAIL="${ALERT_EMAIL:-}"

# Unbuffered: a log that only appears when the process ends is useless for
# diagnosing a run that hangs.
export PYTHONUNBUFFERED=1

DATE=$(date -u +%F)
LOG="logs/${DATE}.log"
mkdir -p logs

# 铁律 4 says a failure must never be silent.  It does not say every failure
# is the same failure.  Two levels, because an alarm that is always red is an
# alarm nobody reads:
#
#   ALERT  the day's data is lost or at risk -- collection or export failed
#   WARN   the data was collected and archived, but something around it did
#          not work: part of the run was lost, or backup/publish failed
#
# check_freshness.sh treats ALERT as red and WARN as a warning it prints
# without failing.
notify() {
    local level="$1" body="$2"
    echo "${level}: ${body}" >&2
    printf '%s\n' "${body}" > "${ROOT}/logs/${level}-${DATE}.txt"
    bash scripts/notify.sh "${level}" "${body}" || true
}

# Every step runs even if an earlier one failed.  A partial day still wrote a
# real archive that must be backed up, and a failed day's summary is exactly
# the one the public record most needs to show.
collect_rc=0
export_rc=0
aux_rc=0
{
    echo "=== ModelPass daily run ${DATE} ==="
    python -m src.collect --source huggingface --top "${MODELPASS_TOP:-1000}" || collect_rc=$?
    python -m src.export --date "${DATE}"                                     || export_rc=1
    python -m src.site                                                        || export_rc=1
    bash scripts/backup.sh                                                    || aux_rc=1
    if [ -d .git ]; then
        bash scripts/publish.sh                                               || aux_rc=1
    else
        echo "publish: no git repo here (container?); run scripts/publish.sh on the host"
    fi
    echo "=== done (collect=${collect_rc} export=${export_rc} aux=${aux_rc}) ==="
} >> "${LOG}" 2>&1

# collect exits 0 success, 1 failed, 2 partial.
if [ "${collect_rc}" -eq 1 ] || [ "${export_rc}" -ne 0 ]; then
    notify ALERT "${DATE}:采集或导出失败(collect=${collect_rc} export=${export_rc})。这一天可能补不回来。\n日志:${ROOT}/${LOG}"
    exit 1
fi

# Collection succeeded, so today's data exists.  Clear any red flag left by an
# earlier day -- a good day clears the board, or yesterday's failure stays lit
# forever and the alarm stops meaning anything.
rm -f "${ROOT}"/logs/ALERT-*.txt

if [ "${collect_rc}" -eq 2 ] || [ "${aux_rc}" -ne 0 ]; then
    WARN_WHY=""
    [ "${collect_rc}" -eq 2 ] && WARN_WHY="部分模型没采到(partial run)"
    if [ "${aux_rc}" -ne 0 ]; then
        [ -n "${WARN_WHY}" ] && WARN_WHY="${WARN_WHY};"
        WARN_WHY="${WARN_WHY}备份或发布失败 —— 今天的归档只存在于这一台机器上"
    fi
    notify WARN "${DATE}:数据已采集并归档,但 ${WARN_WHY}。\n日志:${ROOT}/${LOG}"
    exit 2
fi

rm -f "${ROOT}"/logs/WARN-*.txt

# A clean day is not worth a notification on its own -- that is what the daily
# commit is for. But a day that actually found something is: a licence change
# is the entire point of running this, and it should reach a phone the day it
# happens, not whenever someone next opens the repo.
python -m src.export --date "${DATE}" --digest --only-notable 2>/dev/null \
    | { read -r first || exit 0; { printf '%s\n' "${first}"; cat; } \
        | bash scripts/notify.sh INFO - ; } || true
