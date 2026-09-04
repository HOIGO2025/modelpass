#!/usr/bin/env bash
# Commit the day's summary (and only the summary) to the public repo.
#
# GitHub's commit timestamp is a third party attesting that we held this
# data on this date.  Raw archives never leave the collection host.
set -euo pipefail
cd "$(dirname "$0")/.."

DATE="${1:-$(date -u +%F)}"
FILE="data/daily/${DATE}.md"

[ -f "${FILE}" ] || { echo "publish.sh: ${FILE} does not exist" >&2; exit 1; }

git add "${FILE}"
if git diff --cached --quiet; then
    echo "publish.sh: nothing new to commit for ${DATE}"
    exit 0
fi

ROOT_HASH="$(sqlite3 "${MODELPASS_DB:-db/modelpass.db}" \
    "SELECT COALESCE(GROUP_CONCAT(merkle_root, ' '), 'none') FROM runs
     WHERE substr(started_at,1,10)='${DATE}' AND merkle_root IS NOT NULL;")"

git commit -q -m "data: ${DATE}" -m "merkle_root: ${ROOT_HASH}"
if git remote get-url origin >/dev/null 2>&1; then
    git push -q origin HEAD
    echo "publish.sh: committed and pushed ${FILE}"
else
    echo "publish.sh: committed ${FILE} (no 'origin' remote configured; not pushed)"
fi
