"""Compute what changed, by comparing adjacent observations.

`changes` is derived data: it can be deleted and recomputed from
`observations` at any time.  `observations` cannot (铁律 1) -- nothing in
this file writes to it.

"Adjacent" means the immediately preceding observation *of the same entity*
by observed_at, whatever day that was.  That handles reruns, gaps, and
back-filled replays without special cases.
"""
import argparse
import json
import sys

from . import archive
from .db import ROOT, connect
from .sources import huggingface

# Columns worth watching.  Ordered by how much a change matters.
FIELDS = [
    "declared_license",
    "has_license_file",
    "license_file_path",
    "is_gated",
    "is_private",
    "base_model_ref",
    "revision",
    "pipeline_tag",
    "last_modified",
    "tags_json",
    "downloads",
    "likes",
]

SOURCE_MODULES = {"huggingface": huggingface}


def severity(field, old, new):
    """铁律-free zone: this is a fixed table, not a judgement (see README)."""
    if field == "presence":
        return "high"
    if field == "declared_license":
        return "high"
    if field == "has_license_file" and _int(old) == 1 and _int(new) == 0:
        return "high"
    if field == "is_gated" and _int(old) == 0 and _int(new) == 1:
        return "high"
    if field in ("base_model_ref", "revision"):
        return "medium"
    return "low"


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _text(v):
    return None if v is None else str(v)


def _pair_query():
    cols = ", ".join(f"p.{f} AS prev_{f}, c.{f} AS curr_{f}" for f in FIELDS)
    return f"""
        SELECT c.id AS curr_id, c.entity_id AS entity_id, p.id AS prev_id, {cols}
        FROM observations c
        JOIN observations p ON p.id = (
            SELECT x.id FROM observations x
            WHERE x.entity_id = c.entity_id
              AND (x.observed_at < c.observed_at
                   OR (x.observed_at = c.observed_at AND x.id < c.id))
            ORDER BY x.observed_at DESC, x.id DESC
            LIMIT 1
        )
        WHERE c.observed_date = ?
        ORDER BY c.entity_id, c.id
    """


def compute(con, date, verbose=False):
    """Recompute every change detected on `date`.  Returns counts by severity."""
    # `changes` is derived -- clearing it is not a data loss.  (Note that
    # nothing anywhere deletes from `observations`.)
    con.execute("DELETE FROM changes WHERE detected_date = ?", (date,))

    rows = []
    for r in con.execute(_pair_query(), (date,)):
        for field in FIELDS:
            old, new = r[f"prev_{field}"], r[f"curr_{field}"]
            if old == new:
                continue
            rows.append(
                (
                    r["entity_id"],
                    date,
                    field,
                    _text(old),
                    _text(new),
                    r["prev_id"],
                    r["curr_id"],
                    severity(field, old, new),
                )
            )

    rows.extend(_presence_rows(con, date))

    con.executemany(
        "INSERT INTO changes"
        " (entity_id, detected_date, field, old_value, new_value,"
        "  prev_obs_id, curr_obs_id, severity)"
        " VALUES (?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()

    counts = {"high": 0, "medium": 0, "low": 0}
    for row in rows:
        counts[row[7]] = counts.get(row[7], 0) + 1
    counts["total"] = len(rows)
    if verbose:
        print(
            f"[diff] {date}: {counts['total']} changes "
            f"(high={counts['high']} medium={counts['medium']} low={counts['low']})"
        )
    return counts


def _presence_rows(con, date):
    """A model we asked for and the hub would not give us any more.

    Deliberately narrow: only ids the day's manifests recorded with an
    absence status (see the source module).
    A model that merely fell out of today's top-N was never asked about, so
    it produces nothing -- silence is not evidence of disappearance.
    """
    out = []
    seen = set()
    runs = con.execute(
        "SELECT source, archive_path FROM runs"
        " WHERE substr(started_at,1,10)=? AND archive_path IS NOT NULL",
        (date,),
    ).fetchall()
    for run in runs:
        manifest = archive.load_manifest(run["archive_path"])
        if not manifest:
            continue
        absent = getattr(SOURCE_MODULES.get(run["source"]), "ABSENT_STATUS", (404, 410))
        for rec in manifest.get("records", []):
            status = rec.get("http_status")
            if status not in absent:
                continue
            key = (run["source"], rec["external_id"])
            if key in seen:
                continue
            seen.add(key)
            ent = con.execute(
                "SELECT id FROM entities WHERE source=? AND external_id=?", key
            ).fetchone()
            if not ent:
                continue  # never successfully observed: nothing to compare
            eid = ent["id"]
            today = con.execute(
                "SELECT 1 FROM observations WHERE entity_id=? AND observed_date=? LIMIT 1",
                (eid, date),
            ).fetchone()
            if today:
                continue  # observed fine elsewhere in the day; not gone
            prev = con.execute(
                "SELECT id FROM observations WHERE entity_id=? AND observed_date<?"
                " ORDER BY observed_at DESC, id DESC LIMIT 1",
                (eid, date),
            ).fetchone()
            if not prev:
                continue
            out.append(
                (
                    eid, date, "presence", "present", f"absent (HTTP {status})",
                    prev["id"], None, "high",
                )
            )
    return out


def dates_with_observations(con):
    return [
        r[0]
        for r in con.execute(
            "SELECT DISTINCT observed_date FROM observations ORDER BY observed_date"
        )
    ]


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m src.diff")
    ap.add_argument("--date", help="YYYY-MM-DD (UTC)")
    ap.add_argument("--all", action="store_true", help="recompute every date")
    ap.add_argument("--db", help="database path (default db/modelpass.db)")
    args = ap.parse_args(argv)

    if not args.date and not args.all:
        ap.error("give --date YYYY-MM-DD or --all")

    con = connect(args.db)
    try:
        targets = dates_with_observations(con) if args.all else [args.date]
        for d in targets:
            compute(con, d, verbose=True)
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
