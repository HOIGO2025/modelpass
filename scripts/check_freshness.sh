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

# Markers left by daily.sh, so a failure is visible even when the mail did not
# get out.  WARN is printed and moved past; only ALERT is red.  An alarm that
# is permanently red -- because, say, no backup target is configured yet -- is
# an alarm that gets ignored, which is the outcome 铁律 4 exists to prevent.
for w in logs/WARN-*.txt; do
    [ -e "${w}" ] || continue
    echo "warning: $(cat "${w}")" >&2
done
MARKERS="$(ls -1 logs/ALERT-*.txt 2>/dev/null || true)"
if [ -n "${MARKERS}" ]; then
    MSG="daily.sh 报告了失败的一天:$(echo "${MARKERS}" | tr '\n' ' ')"
elif [ ! -f "${DB}" ]; then
    MSG="数据库 ${DB} 不存在 —— 采集从未运行过。"
else
    # python3 rather than the sqlite3 CLI: this check has to run on the host,
    # outside the container, and a monitoring script must not need a package
    # installed to tell you monitoring is broken.
    OUT="$(python3 - "${DB}" "${MAX_AGE_HOURS}" <<'PYEOF'
import sqlite3, sys
from datetime import datetime, timezone

db, max_age = sys.argv[1], float(sys.argv[2])
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    row = con.execute(
        "SELECT MAX(finished_at) FROM runs WHERE status IN ('success','partial')"
    ).fetchone()
except sqlite3.Error as exc:
    print(f"STALE|数据库无法读取({exc})")
    raise SystemExit(0)

last = row[0] if row else None
if not last:
    print("STALE|从未有过成功的采集记录")
    raise SystemExit(0)

when = datetime.fromisoformat(last.replace("Z", "+00:00"))
hours = (datetime.now(timezone.utc) - when).total_seconds() / 3600
if hours < max_age:
    print(f"OK|最近一次成功采集 {last},{hours:.1f} 小时前")
else:
    print(
        f"STALE|已经 {hours:.1f} 小时没有成功采集(上次 {last},阈值 "
        f"{max_age:.0f} 小时)。这份时间序列可能已经断了一天。"
    )
PYEOF
)"
    if [ "${OUT%%|*}" = "OK" ]; then
        echo "ok: ${OUT#*|}"
        exit 0
    fi
    MSG="${OUT#*|}"
fi

echo "${MSG}" >&2
mkdir -p logs
printf '%s\n' "${MSG}" >> "logs/freshness-alerts.log"
bash scripts/notify.sh ALERT "${MSG}" || true
exit 1
