#!/usr/bin/env bash
# Commit the daily summaries and the control panel to the public repo.
#
# GitHub's commit timestamp is a third party attesting that we held this data
# on this date. Raw archives never leave the collection host.
#
# Safe to run on any schedule, including hourly: it stages whatever is not yet
# committed and exits quietly when there is nothing new. That keeps it
# independent of the collector's clock -- the container schedules in UTC while
# cron runs in the host's local timezone.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d .git ] || { echo "publish.sh: not a git repository"; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "publish.sh: no origin remote"; exit 1; }

git fetch -q origin || { echo "publish.sh: cannot reach origin" >&2; exit 1; }

# Integrate anything pushed from elsewhere before trying to add to it. Without
# this, one push from a developer's laptop blocks publishing permanently.
# -X theirs keeps this host's version of a conflicting file, which is correct
# because the only files this host commits -- data/daily/ and docs/ -- are
# generated from the database it alone holds.
if [ -n "$(git rev-list HEAD..origin/main 2>/dev/null)" ]; then
    git rebase -q -X theirs origin/main 2>/dev/null || {
        git rebase --abort 2>/dev/null || true
        echo "publish.sh: could not rebase onto origin/main" >&2
        exit 1
    }
fi

# Stage every unpublished summary, not just today's: a day whose publish step
# was missed then repairs itself on the next run instead of staying invisible.
# docs/ is the control panel, regenerated each run and served by GitHub Pages.
git add data/daily/ docs/

if ! git diff --cached --quiet; then
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
fi

# Push whenever this host is ahead -- NOT only when a commit was just made.
# A rejected push leaves the commit sitting locally, so the next run finds
# nothing new to stage and would exit reporting success while the public
# record silently stops. That is exactly how two days went unpublished.
AHEAD="$(git rev-list --count origin/main..HEAD)"
if [ "${AHEAD}" -eq 0 ]; then
    echo "publish.sh: nothing new to publish"
    exit 0
fi

git push -q origin HEAD || { echo "publish.sh: push failed" >&2; exit 1; }

# Trust the remote, not the exit code: confirm the commits actually landed.
git fetch -q origin
STILL="$(git rev-list --count origin/main..HEAD)"
[ "${STILL}" -eq 0 ] || { echo "publish.sh: still ${STILL} commit(s) unpublished" >&2; exit 1; }
echo "publish.sh: published ${AHEAD} commit(s)"
