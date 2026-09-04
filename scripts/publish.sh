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

# Stage every unpublished summary, not just today's: a day the publish step
# was missed then repairs itself on the next run instead of staying invisible.
git add data/daily/
if git diff --cached --quiet; then
    echo "publish.sh: nothing new to commit for ${DATE}"
    exit 0
fi

# Read the roots straight from the day's manifests rather than the database:
# the manifest is the authoritative record, and it keeps the one script that
# must run on the host free of a sqlite3 dependency.
ROOT_HASH="$(python3 scripts/merkle_roots.py "${DATE}")"

PENDING="$(git diff --cached --name-only | sed 's|data/daily/||;s|\.md$||' | tr '\n' ' ')"
git commit -q -m "data: ${DATE}" \
    -m "days in this commit: ${PENDING}" \
    -m "merkle_root: ${ROOT_HASH}"
if git remote get-url origin >/dev/null 2>&1; then
    git push -q origin HEAD
    echo "publish.sh: committed and pushed ${FILE}"
else
    echo "publish.sh: committed ${FILE} (no 'origin' remote configured; not pushed)"
fi
