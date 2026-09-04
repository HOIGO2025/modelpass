#!/usr/bin/env bash
# Scheduler. Deliberately a bash loop rather than a cron daemon inside the
# container: fewer moving parts, env vars just work, and logs go to stdout
# where `docker logs` can see them.
#
# The one thing cron cannot do and this must: CATCH UP. A laptop that was
# asleep at 03:00, or a host that rebooted, would silently skip the day.
# On every start we check whether a successful run is on record, and if not,
# we collect immediately. A day skipped is a day gone forever.
set -euo pipefail
cd /app

# Any argument means "run this one thing and exit" -- one-off collections,
# a replay, a shell. Only the bare container becomes the scheduler.
#   docker compose run --rm modelpass python -m src.collect --top 20
#   docker compose run --rm modelpass bash
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

RUN_AT="${RUN_AT_UTC:-03:00}"
mkdir -p logs data/raw data/daily "$(dirname "${MODELPASS_DB:-db/modelpass.db}")"

echo "[entrypoint] ModelPass container up. Daily run at ${RUN_AT} UTC."
echo "[entrypoint] archives: /app/data ($(df -P /app/data | tail -1 | awk '{print $1}'))"
echo "[entrypoint] database: ${MODELPASS_DB:-db/modelpass.db}"

# Loud, early check that the archive really is on a mount and not in the
# container's own layer, where a rebuild would destroy it.
if ! mountpoint -q /app/data 2>/dev/null && [ -z "${MODELPASS_ALLOW_UNMOUNTED:-}" ]; then
    echo "[entrypoint] WARNING: /app/data is not a mount point."
    echo "[entrypoint] Archives written here die with the container. Bind mount it."
fi

# Mounting over /app/db would hide the schema that ships in the image, and
# every run would die creating its tables. Catch it here, not at 03:00.
if [ ! -f db/schema.sql ]; then
    echo "[entrypoint] FATAL: db/schema.sql is missing -- is a volume mounted over /app/db?" >&2
    echo "[entrypoint] Mount the database at /app/state instead (MODELPASS_DB)." >&2
    exit 1
fi

run_once() {
    echo "[entrypoint] $(date -u +%FT%TZ) starting daily run"
    if MODELPASS_TOP="${TOP:-1000}" bash scripts/daily.sh; then
        echo "[entrypoint] $(date -u +%FT%TZ) run OK"
    else
        # daily.sh has already alerted and left logs/ALERT-*.txt behind.
        # Never exit here: a failed day must not take the scheduler down with
        # it, or one bad night becomes an unbounded gap.
        echo "[entrypoint] $(date -u +%FT%TZ) run FAILED (see logs/); scheduler continues" >&2
    fi
}

# Catch-up on start.
if ! bash scripts/check_freshness.sh; then
    echo "[entrypoint] no fresh successful run on record -- collecting now"
    run_once
fi

next_epoch() {
    local t
    t=$(date -u -d "today ${RUN_AT}" +%s)
    if [ "${t}" -le "$(date -u +%s)" ]; then
        t=$(date -u -d "tomorrow ${RUN_AT}" +%s)
    fi
    echo "${t}"
}

while true; do
    target=$(next_epoch)
    wait_s=$(( target - $(date -u +%s) ))
    echo "[entrypoint] next run at $(date -u -d "@${target}" +%FT%TZ) (in ${wait_s}s)"
    sleep "${wait_s}"
    run_once
    # A long sleep can drift across a suspend/resume; re-check freshness so a
    # missed wake-up is repaired on the next loop rather than waiting a day.
    sleep 5
done
