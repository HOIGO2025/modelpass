#!/usr/bin/env bash
# Copy the irreplaceable half of the project somewhere else.
#
# BACKUP_HOST must be a DIFFERENT PROVIDER in a DIFFERENT REGION from the
# collection host.  Same-provider backup protects against disk failure and
# nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
    set -a; . ./.env; set +a
fi

if [ -z "${BACKUP_HOST:-}" ] && [ -z "${R2_REMOTE:-}" ]; then
    echo "backup.sh: neither BACKUP_HOST nor R2_REMOTE is set;" >&2
    echo "backup.sh: refusing to pretend a backup happened" >&2
    exit 1
fi

# A live SQLite file must never be copied directly -- take a consistent
# snapshot instead.  (The DB is rebuildable from data/raw/ anyway; the
# archives are not rebuildable from anything.)
DB="${MODELPASS_DB:-db/modelpass.db}"
SNAP="$(dirname "${DB}")/snapshot.db"
sqlite3 "${DB}" ".backup ${SNAP}"

rc=0

if [ -n "${BACKUP_HOST:-}" ]; then
    rsync -az --delete \
        "${SNAP}" data/raw/ \
        "${BACKUP_HOST}:/archive/modelpass/" || rc=1
    [ "${rc}" -eq 0 ] && echo "backup.sh: pushed to ${BACKUP_HOST}"
fi

if [ -n "${R2_REMOTE:-}" ]; then
    # Object storage on a different provider in a different region -- which is
    # what "off-site" has to mean.  --immutable matches chmod 444 archives;
    # note there is deliberately no --delete: an archive that vanishes locally
    # must not vanish from the backup too.
    rclone copy --immutable data/raw "${R2_REMOTE}/raw" || rc=1
    rclone copy "${SNAP}" "${R2_REMOTE}/db/" || rc=1
    [ "${rc}" -eq 0 ] && echo "backup.sh: pushed to ${R2_REMOTE}"
fi

exit "${rc}"
