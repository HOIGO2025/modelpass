#!/usr/bin/env bash
# The "it didn't run at all" alarm.
#
# Deliberately a SEPARATE cron entry from daily.sh: if daily.sh dies, the
# alert it would have sent dies with it.  This one only reads the database.
#
#   17 * * * * /opt/modelpass/scripts/check_freshness.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [ -f .env ]; then
    set -a; . ./.env; set +a
fi
ALERT_EMAIL="${ALERT_EMAIL:-}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-25}"
DB="${MODELPASS_DB:-db/modelpass.db}"

# A marker left by daily.sh means the run itself reported trouble, whether or
# not the mail got out.  Trip on it even if the database looks fresh.
MARKERS="$(ls -1 logs/ALERT-*.txt 2>/dev/null || true)"
if [ -n "${MARKERS}" ]; then
    MSG="ModelPass: daily.sh left failure markers: $(echo "${MARKERS}" | tr '\n' ' ')"
elif [ ! -f "${DB}" ]; then
    MSG="ModelPass: database ${DB} does not exist -- collection has never run."
else
    LAST="$(sqlite3 "${DB}" \
        "SELECT COALESCE(MAX(finished_at),'') FROM runs WHERE status IN ('success','partial');")"
    if [ -z "${LAST}" ]; then
        MSG="ModelPass: no successful run has ever been recorded."
    else
        AGE_H="$(sqlite3 "${DB}" \
            "SELECT CAST((julianday('now') - julianday(MAX(finished_at))) * 24 AS INT)
             FROM runs WHERE status IN ('success','partial');")"
        if [ "${AGE_H}" -lt "${MAX_AGE_HOURS}" ]; then
            echo "ok: last successful run ${LAST} (${AGE_H}h ago)"
            exit 0
        fi
        MSG="ModelPass: no successful run for ${AGE_H}h (last: ${LAST}, threshold ${MAX_AGE_HOURS}h). A day of the series may already be lost."
    fi
fi

echo "${MSG}" >&2
mkdir -p logs
printf '%s\n' "${MSG}" >> "logs/freshness-alerts.log"
if [ -n "${ALERT_EMAIL}" ] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "${MSG}" | mail -s "[ModelPass] collection is stale" "${ALERT_EMAIL}" || true
fi
exit 1
