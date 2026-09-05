"""Daily summary markdown + CSV export.

The markdown in data/daily/ is the only thing that goes to git: it is the
public, third-party-timestamped record that we held the data that day.
Raw archives stay on the collection host and the backup host.

This file reports what was observed.  It does not interpret it (铁律 5).
"""
import argparse
import csv
import sys
from pathlib import Path

from .db import ROOT, connect

DAILY_DIR = ROOT / "data" / "daily"
MAX_LISTED = 200  # per severity section


def _fmt(v, width=60):
    if v is None:
        return "_(none)_"
    s = str(v).replace("|", "\\|").replace("\n", " ")
    return s if len(s) <= width else s[: width - 1] + "…"


def _rows(con, sql, params=()):
    return con.execute(sql, params).fetchall()


def render(con, date):
    L = []
    A = L.append

    A(f"# ModelPass — {date}")
    A("")

    runs = _rows(
        con,
        "SELECT * FROM runs WHERE substr(started_at,1,10)=? ORDER BY id",
        (date,),
    )
    obs_total = con.execute(
        "SELECT count(*) FROM observations WHERE observed_date=?", (date,)
    ).fetchone()[0]
    ent_total = con.execute("SELECT count(*) FROM entities").fetchone()[0]
    new_ents = con.execute(
        "SELECT count(*) FROM entities WHERE substr(first_seen,1,10)=?", (date,)
    ).fetchone()[0]

    A(f"- Observations recorded: **{obs_total}**")
    A(f"- Entities seen for the first time today: **{new_ents}**")
    A(f"- Entities tracked in total: **{ent_total}**")
    A("")

    A("## Runs")
    A("")
    if not runs:
        A("**No run recorded for this date.** A gap in the series cannot be back-filled.")
    else:
        A("| id | source | started (UTC) | finished | status | attempted | succeeded | failed |")
        A("|---|---|---|---|---|---|---|---|")
        for r in runs:
            A(
                f"| {r['id']} | {r['source']} | {r['started_at']} | "
                f"{r['finished_at'] or '—'} | **{r['status']}** | {r['attempted']} | "
                f"{r['succeeded']} | {r['failed']} |"
            )
        notes = [r for r in runs if r["error_note"]]
        if notes:
            A("")
            for r in notes:
                A(f"- run {r['id']}: `{_fmt(r['error_note'], 300)}`")
    A("")

    A("## Archive integrity")
    A("")
    archived = [r for r in runs if r["archive_path"]]
    if not archived:
        A("_No archive written for this date._")
    else:
        A("| archive | sha256 | merkle_root |")
        A("|---|---|---|")
        for r in archived:
            A(f"| `{r['archive_path']}` | `{r['archive_sha256']}` | `{r['merkle_root']}` |")
        A("")
        A("Verify with: `python scripts/verify_merkle.py <archive.jsonl.gz>`")
    A("")

    counts = dict(
        _rows(
            con,
            "SELECT severity, count(*) FROM changes WHERE detected_date=? GROUP BY severity",
            (date,),
        )
    )
    total = sum(counts.values())
    # How many of today's observations actually had a predecessor to compare
    # against?  Zero means "first sighting", which is not the same as "nothing
    # changed" -- and on day one of a series it is the only honest thing to say.
    comparable = con.execute(
        "SELECT count(*) FROM observations c WHERE c.observed_date=? AND EXISTS ("
        " SELECT 1 FROM observations x WHERE x.entity_id=c.entity_id"
        " AND (x.observed_at < c.observed_at"
        "      OR (x.observed_at = c.observed_at AND x.id < c.id)))",
        (date,),
    ).fetchone()[0]

    A("## Changes")
    A("")
    A(
        f"- high: **{counts.get('high', 0)}** · medium: **{counts.get('medium', 0)}**"
        f" · low: **{counts.get('low', 0)}** · total: **{total}**"
    )
    A(f"- observations with a previous one to compare against: **{comparable}** of {obs_total}")
    A("")
    if comparable == 0 and obs_total:
        A(
            "_First observation of everything recorded here — there is nothing"
            " yet to compare against. The comparisons start with the next run._"
        )
        A("")
    elif total == 0:
        A(
            "_No change against the previous observation. That is itself a"
            " recorded fact: on this date, nothing moved._"
        )
        A("")

    for sev in ("high", "medium"):
        rows = _rows(
            con,
            "SELECT e.external_id, e.source, c.field, c.old_value, c.new_value"
            " FROM changes c JOIN entities e ON e.id=c.entity_id"
            " WHERE c.detected_date=? AND c.severity=?"
            " ORDER BY c.field, e.external_id LIMIT ?",
            (date, sev, MAX_LISTED + 1),
        )
        if not rows:
            continue
        A(f"### {sev}")
        A("")
        A("| model | field | before | after |")
        A("|---|---|---|---|")
        for r in rows[:MAX_LISTED]:
            A(
                f"| [{r['external_id']}](https://huggingface.co/{r['external_id']}) "
                f"| `{r['field']}` | {_fmt(r['old_value'])} | {_fmt(r['new_value'])} |"
            )
        if len(rows) > MAX_LISTED:
            A("")
            A(f"_… truncated at {MAX_LISTED}; query the database for the rest._")
        A("")

    low_by_field = _rows(
        con,
        "SELECT field, count(*) n FROM changes WHERE detected_date=? AND severity='low'"
        " GROUP BY field ORDER BY n DESC",
        (date,),
    )
    if low_by_field:
        A("### low (by field)")
        A("")
        A("| field | count |")
        A("|---|---|")
        for r in low_by_field:
            A(f"| `{r['field']}` | {r['n']} |")
        A("")

    A("---")
    A("")
    A(
        "Generated by ModelPass. Observations are append-only; this summary is"
        " derived and can be regenerated with `python -m src.export --date"
        f" {date}`."
    )
    A("")
    return "\n".join(L)


def write_daily(con, date, verbose=False):
    DAILY_DIR.mkdir(parents=True, exist_ok=True)
    path = DAILY_DIR / f"{date}.md"
    path.write_text(render(con, date), encoding="utf-8")
    if verbose:
        print(f"[export] wrote {path}")
    return path


def digest(con, date):
    """Short plain-text summary of a day, for a notification.

    Only what would make someone look: run trouble, and high/medium changes.
    Nobody needs a push notification about 121 likes.
    """
    L = []
    runs = _rows(con, "SELECT * FROM runs WHERE substr(started_at,1,10)=? ORDER BY id", (date,))
    bad = [r for r in runs if r["status"] not in ("success",)]
    if not runs:
        L.append(f"{date}:没有任何运行记录。这一天补不回来。")
    else:
        ok = [r for r in runs if r["status"] == "success"]
        tot = sum(r["succeeded"] for r in runs)
        L.append(f"{date}:{len(ok)}/{len(runs)} 次运行成功,记录 {tot} 条观测")
        for r in bad:
            L.append(
                f"  ! run {r['id']} {r['status']}:"
                f"成功 {r['succeeded']}/{r['attempted']},丢失 {r['failed']} 个模型"
            )

    counts = dict(_rows(con, "SELECT severity, count(*) FROM changes WHERE detected_date=?"
                             " GROUP BY severity", (date,)))
    L.append(f"变更:high {counts.get('high',0)} · medium {counts.get('medium',0)}"
             f" · low {counts.get('low',0)}")

    for sev in ("high", "medium"):
        rows = _rows(con,
            "SELECT e.external_id, c.field, c.old_value, c.new_value"
            " FROM changes c JOIN entities e ON e.id=c.entity_id"
            " WHERE c.detected_date=? AND c.severity=? ORDER BY c.field LIMIT 15",
            (date, sev))
        if not rows:
            continue
        L.append("")
        L.append(f"{sev.upper()}({'需要立刻看' if sev == 'high' else '留意'}):")
        for r in rows:
            L.append(f"  {r['external_id']}")
            L.append(f"    {r['field']}: {_fmt(r['old_value'], 34)} -> {_fmt(r['new_value'], 34)}")
    return "\n".join(L)


def has_notable(con, date):
    """Is there anything here worth interrupting someone for?"""
    n = con.execute(
        "SELECT count(*) FROM changes WHERE detected_date=? AND severity IN ('high','medium')",
        (date,),
    ).fetchone()[0]
    bad = con.execute(
        "SELECT count(*) FROM runs WHERE substr(started_at,1,10)=? AND status<>'success'",
        (date,),
    ).fetchone()[0]
    return n > 0 or bad > 0


def write_csv(con, outdir, date=None):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    written = []
    specs = [
        (
            "observations",
            "SELECT e.source, e.external_id, o.* FROM observations o"
            " JOIN entities e ON e.id=o.entity_id"
            + (" WHERE o.observed_date=?" if date else "")
            + " ORDER BY o.id",
        ),
        (
            "changes",
            "SELECT e.source, e.external_id, c.* FROM changes c"
            " JOIN entities e ON e.id=c.entity_id"
            + (" WHERE c.detected_date=?" if date else "")
            + " ORDER BY c.id",
        ),
        ("entities", "SELECT * FROM entities ORDER BY id"),
        ("runs", "SELECT * FROM runs ORDER BY id"),
    ]
    for name, sql in specs:
        params = (date,) if (date and "?" in sql) else ()
        cur = con.execute(sql, params)
        cols = [d[0] for d in cur.description]
        suffix = f".{date}" if date and name in ("observations", "changes") else ""
        path = outdir / f"{name}{suffix}.csv"
        with open(path, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(cols)
            w.writerows(cur)
        written.append(path)
    return written


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m src.export")
    ap.add_argument("--date", help="YYYY-MM-DD (UTC)")
    ap.add_argument("--csv", metavar="DIR", help="also dump tables as CSV into DIR")
    ap.add_argument("--digest", action="store_true",
                    help="print a short plain-text digest for --date and exit")
    ap.add_argument("--only-notable", action="store_true",
                    help="with --digest, print nothing unless something is worth reporting")
    ap.add_argument("--db", help="database path (default db/modelpass.db)")
    args = ap.parse_args(argv)

    con = connect(args.db)
    try:
        if args.digest:
            if not args.date:
                ap.error("--digest needs --date")
            if args.only_notable and not has_notable(con, args.date):
                return 0
            print(digest(con, args.date))
            return 0
        if args.date:
            write_daily(con, args.date, verbose=True)
        elif not args.csv:
            ap.error("give --date YYYY-MM-DD and/or --csv DIR")
        if args.csv:
            for p in write_csv(con, args.csv, args.date):
                print(f"[export] wrote {p}")
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
