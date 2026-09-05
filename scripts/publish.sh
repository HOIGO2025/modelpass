#!/usr/bin/env bash
# Commit the daily summaries (and only the summaries) to the public repo.
#
# GitHub's commit timestamp is a third party attesting that we held this data
# on this date. Raw archives never leave the collection host.
#
# Safe to run on any schedule, including hourly: it stages whatever summaries
# are not yet committed and exits quietly when there is nothing new. That makes
# it independent of the collector's clock -- which matters, because the
# container schedules in UTC while cron runs in the host's local timezone.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d .git ] || { echo "publish.sh: not a git repository"; exit 1; }

# Stage every unpublished summary, not just today's: a day whose publish step
# was missed then repairs itself on the next run instead of staying invisible.
# docs/ is the control panel, regenerated each run and served by GitHub Pages.
git add data/daily/ docs/

if git diff --cached --quiet; then
    echo "publish.sh: nothing new to publish"
    exit 0
fi

# `grep` exits 1 when nothing matches, and the panel changes on every run
# while a new summary appears only once a day -- so "docs/ only" is the
# common case, and it must not abort the script under `set -e`.
DAYS="$(git diff --cached --name-only \
        | { grep '^data/daily/' || :; } | sed 's|.*/||; s|\.md$||' \
        | sort | tr '\n' ' ' | sed 's/ $//')"
LATEST="${DAYS##* }"
[ -n "${LATEST}" ] || LATEST="$(date -u +%F)"
[ -n "${DAYS}" ] || DAYS="(panel only)"

ROOT_HASH="$(python3 scripts/merkle_roots.py "${LATEST}")"

SUBJECT="data: ${LATEST}"
[ "${DAYS}" = "(panel only)" ] && SUBJECT="panel: ${LATEST}"
git commit -q -m "${SUBJECT}" \
    -m "days in this commit: ${DAYS}" \
    -m "merkle_root: ${ROOT_HASH}"

if git remote get-url origin >/dev/null 2>&1; then
    git push -q origin HEAD
    echo "publish.sh: published ${DAYS}"
else
    echo "publish.sh: committed ${DAYS} (no 'origin' remote; not pushed)"
fi
