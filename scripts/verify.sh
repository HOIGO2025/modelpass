#!/usr/bin/env bash
# Weekly restore drill.  An unverified backup is not a backup.
#
#   0 5 * * 0 /opt/modelpass/scripts/verify.sh
#
# Pulls one random day back from the backup host, unpacks it, re-verifies
# every hash and the Merkle root, and appends the verdict to logs/verify.log.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [ -f .env ]; then
    set -a; . ./.env; set +a
fi
ALERT_EMAIL="${ALERT_EMAIL:-}"
SOURCE="${1:-huggingface}"
LOG="logs/verify.log"
mkdir -p logs

fail() {
    echo "$(date -u +%FT%TZ) FAIL $*" | tee -a "${LOG}" >&2
    if [ -n "${ALERT_EMAIL}" ] && command -v mail >/dev/null 2>&1; then
        echo "ModelPass restore drill FAILED: $*" | \
            mail -s "[ModelPass] restore drill failed" "${ALERT_EMAIL}" || true
    fi
    exit 1
}

if [ -z "${BACKUP_HOST:-}" ] && [ -z "${R2_REMOTE:-}" ]; then
    fail "neither BACKUP_HOST nor R2_REMOTE is set"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Pick a random archived day that exists on the BACKUP side, not locally --
# the point is to prove the remote copy is good, not the one we already have.
if [ -n "${R2_REMOTE:-}" ]; then
    DAY_FILE="$(rclone lsf "${R2_REMOTE}/raw/${SOURCE}" --include '*.jsonl.gz' 2>/dev/null \
                | sort -R | head -1)" || fail "cannot list ${R2_REMOTE}"
    [ -n "${DAY_FILE}" ] || fail "no archives found in ${R2_REMOTE}/raw/${SOURCE}"
    BASE="${DAY_FILE%.jsonl.gz}"
    rclone copy "${R2_REMOTE}/raw/${SOURCE}/${DAY_FILE}" "${WORK}/" \
        || fail "rclone copy failed for ${DAY_FILE}"
    rclone copy "${R2_REMOTE}/raw/${SOURCE}/${BASE}.manifest.json" "${WORK}/" \
        || fail "rclone copy failed for the manifest of ${DAY_FILE}"
else
    DAY_FILE="$(ssh "${BACKUP_HOST}" \
        "ls /archive/modelpass/${SOURCE}/*.jsonl.gz 2>/dev/null" | sort -R | head -1)" \
        || fail "cannot list archives on ${BACKUP_HOST}"
    [ -n "${DAY_FILE}" ] || fail "no archives found on ${BACKUP_HOST}"
    BASE="${DAY_FILE%.jsonl.gz}"
    scp -q "${BACKUP_HOST}:${DAY_FILE}" "${WORK}/" || fail "scp failed for ${DAY_FILE}"
    scp -q "${BACKUP_HOST}:${BASE}.manifest.json" "${WORK}/" \
        || fail "scp failed for the manifest of ${DAY_FILE}"
fi

LOCAL="${WORK}/$(basename "${DAY_FILE}")"
chmod u+w "${LOCAL}" "${WORK}/$(basename "${BASE}").manifest.json" 2>/dev/null || true

# Host runs use the venv; the container installs deps system-wide.
if [ -f .venv/bin/activate ]; then
    # shellcheck disable=SC1091
    source .venv/bin/activate
fi
export PYTHONUNBUFFERED=1
python scripts/verify_merkle.py "${LOCAL}" >> "${LOG}" 2>&1 \
    || fail "hash/merkle verification failed for ${DAY_FILE}"

# And prove the data is actually usable, not merely intact: rebuild a
# throwaway database from the restored archive.
python -m src.collect --replay "${LOCAL}" --db "${WORK}/restore.db" >> "${LOG}" 2>&1 \
    || fail "replay of ${DAY_FILE} failed"
ROWS="$(sqlite3 "${WORK}/restore.db" "SELECT count(*) FROM observations;")"
[ "${ROWS}" -gt 0 ] || fail "replay of ${DAY_FILE} produced no observations"

echo "$(date -u +%FT%TZ) OK ${DAY_FILE} restored, verified, ${ROWS} observations replayed" \
    | tee -a "${LOG}"
