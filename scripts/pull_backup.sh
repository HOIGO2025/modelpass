#!/usr/bin/env bash
# Pull the archives down from the collection host, and verify them.
#
# Runs on a machine that is NOT the collection host -- a laptop, a NAS, any
# box that can ssh out. Pull, not push, and that is the whole point:
#
#   the collection host holds no credential for this copy, so whatever
#   happens to that host -- compromise, ransomware, a bad `rm -rf`, a
#   cloud account suspended -- cannot reach this copy.
#
# R2 and a git remote are both push targets: the server holds write
# credentials for them, so anything that owns the server owns those backups
# too. This one it cannot touch. Keep both: this copy is the immutable one,
# R2 is the one that runs even when the laptop is shut.
#
#   MODELPASS_HOST        ssh target of the collection host. Prefer a direct
#                         route: a Cloudflare Access tunnel works but costs a
#                         lot of throughput (measured 21 KB/s vs direct).
#   MODELPASS_REMOTE_DIR  its project directory (default ~/modelpass)
#   MODELPASS_MIRROR      where to keep the copy (default ~/modelpass-backup)
#
# Deliberately never deletes. An archive that vanishes upstream must not
# vanish here -- that disappearance is exactly what a backup is for.
set -euo pipefail

HOST="${MODELPASS_HOST:-lisong-cf}"
REMOTE="${MODELPASS_REMOTE_DIR:-modelpass}"
MIRROR="${MODELPASS_MIRROR:-${HOME}/modelpass-backup}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date -u +%FT%TZ)"

mkdir -p "${MIRROR}/data/raw" "${MIRROR}/db" "${MIRROR}/logs"
LOG="${MIRROR}/logs/pull.log"

say() { printf '%s %s\n' "${STAMP}" "$*" | tee -a "${LOG}"; }
die() {
    say "FAIL $*"
    bash "${HERE}/notify.sh" ALERT "备份拉取失败:$*
镜像目录:${MIRROR}" 2>/dev/null || true
    exit 1
}

say "pull from ${HOST}:${REMOTE} -> ${MIRROR}"

# A consistent snapshot, taken on the server, of a database that is being
# written to. Never copy a live SQLite file.
ssh -o BatchMode=yes "${HOST}" \
    "cd ${REMOTE} && docker compose exec -T modelpass sqlite3 /app/state/modelpass.db \
     '.backup /app/logs/snapshot.db'" >/dev/null 2>&1 \
    || say "warn: could not snapshot the database (archives are what matter)"

# No --delete, on purpose. See the header.
# Plain flags only: this runs on whatever laptop or NAS you have, and macOS
# still ships rsync 2.6.9 from 2006, which has none of the modern options.
rsync -az --stats \
    "${HOST}:${REMOTE}/data/raw/" "${MIRROR}/data/raw/" >>"${LOG}" 2>&1 \
    || die "rsync of data/raw failed"
rsync -az "${HOST}:${REMOTE}/data/daily/" "${MIRROR}/data/daily/" >>"${LOG}" 2>&1 \
    || say "warn: rsync of data/daily failed"
rsync -az "${HOST}:${REMOTE}/logs/snapshot.db" "${MIRROR}/db/modelpass.db" >>"${LOG}" 2>&1 \
    || say "warn: no database snapshot pulled"

# An unverified backup is not a backup. Re-hash everything we hold, with the
# standalone verifier that shares no code with the collector.
VERIFY_OUT="$(mktemp)"
rc=0
for d in "${MIRROR}"/data/raw/*/; do
    [ -d "${d}" ] || continue
    python3 "${HERE}/verify_merkle.py" --all "${d}" >>"${VERIFY_OUT}" 2>&1 || rc=1
done
cat "${VERIFY_OUT}" >>"${LOG}"
# `grep -c` prints 0 AND exits 1 when nothing matches, so `|| echo 0` would
# append a second zero and the count becomes "0\n0".
OK=$(grep -c '^OK ' "${VERIFY_OUT}" 2>/dev/null || true)
BAD=$(grep -c '^FAIL ' "${VERIFY_OUT}" 2>/dev/null || true)
OK=${OK:-0}
BAD=${BAD:-0}
rm -f "${VERIFY_OUT}"

BYTES=$(du -sk "${MIRROR}/data/raw" 2>/dev/null | cut -f1)
say "verified ${OK} archive(s), ${BAD} failed, mirror holds $((BYTES/1024)) MB"

python3 - "${MIRROR}/status.json" "${STAMP}" "${OK}" "${BAD}" "${BYTES}" <<'PY'
import json, sys
path, stamp, ok, bad, kb = sys.argv[1:6]
json.dump({"pulled_at": stamp, "archives_ok": int(ok), "archives_failed": int(bad),
           "mirror_kb": int(kb)}, open(path, "w"), indent=1)
open(path, "a").write("\n")
PY

[ "${rc}" -eq 0 ] || die "${BAD} archive(s) failed verification in the mirror"
[ "${OK}" -gt 0 ] || die "the mirror holds no verifiable archive"
say "OK"
