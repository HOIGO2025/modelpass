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

alert() {
    # 铁律 4: never fail silently.  Mail if we can, and always leave a marker
    # file behind -- check_freshness.sh trips on it, so an unreachable MTA
    # cannot turn a failure into silence.
    local body="$1"
    echo "${body}" >&2
    printf '%s\n' "${body}" > "${ROOT}/logs/ALERT-${DATE}.txt"
    if [ -n "${ALERT_EMAIL}" ] && command -v mail >/dev/null 2>&1; then
        printf '%s\n' "${body}" | mail -s "[ModelPass] daily run failed" "${ALERT_EMAIL}" || true
    fi
}

# Every step runs even if an earlier one failed.  A partial day still wrote a
# real archive that must be backed up, and a failed day's summary is exactly
# the one the public record most needs to show.
rc=0
{
    echo "=== ModelPass daily run ${DATE} ==="
    python -m src.collect --source huggingface --top "${MODELPASS_TOP:-1000}" || rc=$?
    python -m src.export --date "${DATE}"                  || rc=1
    bash scripts/backup.sh                                 || rc=1
    if [ -d .git ]; then
        bash scripts/publish.sh "${DATE}"                  || rc=1
    else
        echo "publish: no git repo here (container?); run scripts/publish.sh on the host"
    fi
    echo "=== done (rc=${rc}) ==="
} >> "${LOG}" 2>&1

if [ "${rc}" -ne 0 ]; then
    alert "ModelPass daily run ${DATE} finished with rc=${rc}; see ${ROOT}/${LOG}"
    exit 1
fi

# A good day clears the board.  Only clearing today's marker would leave
# yesterday's failure flag up forever, and check_freshness.sh trips on it.
rm -f "${ROOT}"/logs/ALERT-*.txt
