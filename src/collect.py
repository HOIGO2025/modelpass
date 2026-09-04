"""Collection entry point.

    python -m src.collect --source huggingface --top 1000
    python -m src.collect --source huggingface --list config/watchlist.txt
    python -m src.collect --replay 2026-09-04          # no network at all

Order matters and is not negotiable:

    1. open a `runs` row  (status=running)
    2. get the target list
    3. fetch each model, appending the raw response to today's jsonl
       *before* anything is parsed or inserted
    4. freeze the jsonl into {date}.jsonl.gz + manifest (sha256, merkle root)
    5. parse the frozen archive and INSERT entities/observations
    6. close the `runs` row
    7. diff
    8. export

Step 3 lands on disk first so that a crash anywhere after it is recoverable
with --replay.  Step 5 reads the .gz, not the temp file, so live collection
and replay go through exactly one code path.

Exit codes: 0 success · 1 failed · 2 partial.
"""
import argparse
import hashlib
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

from . import archive, diff, export
from .db import ROOT, connect, rel
from .sources import huggingface

SOURCES = {"huggingface": huggingface}


def utcnow():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def today():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


# --------------------------------------------------------------- runs row --


def start_run(con, source):
    cur = con.execute(
        "INSERT INTO runs (source, started_at, status) VALUES (?,?,'running')",
        (source, utcnow()),
    )
    con.commit()
    return cur.lastrowid


def finish_run(con, run_id, status, **fields):
    fields["finished_at"] = utcnow()
    fields["status"] = status
    sets = ", ".join(f"{k}=?" for k in fields)
    con.execute(f"UPDATE runs SET {sets} WHERE id=?", (*fields.values(), run_id))
    con.commit()


# ---------------------------------------------------------------- ingest ---


OBS_COLUMNS = [
    "revision",
    "declared_license",
    "has_license_file",
    "license_file_path",
    "downloads",
    "likes",
    "pipeline_tag",
    "base_model_ref",
    "tags_json",
    "is_gated",
    "is_private",
    "last_modified",
]


def ingest_archive(con, source, archive_path, verbose=True):
    """Parse a frozen archive into entities + observations.

    One transaction for the whole file: a crash mid-ingest rolls back
    cleanly, so --replay never has to reason about half-loaded days.
    Never updates or deletes an observation (铁律 1).
    """
    mod = SOURCES[source]
    abs_path = archive_path if Path(archive_path).is_absolute() else ROOT / archive_path
    stored = rel(abs_path)
    inserted, skipped, dates = 0, 0, set()

    con.execute("BEGIN")
    try:
        for rec in archive.read_archive(abs_path):
            if rec.get("kind") != "model" or rec.get("http_status") != 200:
                continue
            raw = rec["raw"]
            if hashlib.sha256(raw.encode("utf-8")).hexdigest() != rec["raw_sha256"]:
                raise ValueError(
                    f"raw_sha256 mismatch for {rec.get('external_id')} in {stored}"
                )
            try:
                obs = mod.parse_observation(raw)
            except Exception as exc:  # keep the raw, lose only this row
                skipped += 1
                print(
                    f"[ingest] parse failed for {rec.get('external_id')}: {exc}",
                    file=sys.stderr,
                )
                continue
            ext = obs["external_id"] or rec["external_id"]
            fetched_at = rec["fetched_at"]
            con.execute(
                "INSERT OR IGNORE INTO entities (source, external_id, source_url, first_seen)"
                " VALUES (?,?,?,?)",
                (source, ext, obs["source_url"], fetched_at),
            )
            eid = con.execute(
                "SELECT id FROM entities WHERE source=? AND external_id=?", (source, ext)
            ).fetchone()[0]
            cols = ", ".join(OBS_COLUMNS)
            marks = ", ".join("?" for _ in OBS_COLUMNS)
            con.execute(
                f"INSERT INTO observations"
                f" (entity_id, observed_at, observed_date, {cols}, raw_sha256, archive_path)"
                f" VALUES (?,?,?,{marks},?,?)",
                (
                    eid,
                    fetched_at,
                    fetched_at[:10],
                    *[obs[c] for c in OBS_COLUMNS],
                    rec["raw_sha256"],
                    stored,
                ),
            )
            inserted += 1
            dates.add(fetched_at[:10])
        con.commit()
    except Exception:
        con.rollback()
        raise

    if verbose:
        note = f" ({skipped} unparseable, raw kept)" if skipped else ""
        print(f"[ingest] {stored}: {inserted} observations{note}")
    return inserted, skipped, sorted(dates)


# ---------------------------------------------------------------- collect --


def collect(source, top=None, listfile=None, db=None):
    mod = SOURCES[source]
    # data/daily/ is the committed public record.  Only a run against the real
    # database may rewrite it -- a scratch --db (restore drill, verification)
    # must never clobber it.
    publish = db is None
    con = connect(db)
    run_id = start_run(con, source)
    date = today()
    tmp = archive.temp_path(source, date, run_id)

    attempted = recorded = failed = gone = 0
    notes = []
    archive_rel = archive_sha = merkle = None
    status = "failed"

    try:
        session = mod.build_session()

        # --- 2. target list ---------------------------------------------
        raw_pages = []
        if listfile:
            targets = mod.read_watchlist(listfile)
            print(f"[collect] {len(targets)} targets from {listfile}")
        else:
            targets, raw_pages = mod.list_targets(session, top)
            print(f"[collect] {len(targets)} targets from top-{top} listing")
        if not targets:
            raise mod.FetchError("empty target list")
        attempted = len(targets)

        # --- 3. fetch, writing raw responses to disk as they arrive ------
        with open(tmp, "w", encoding="utf-8") as fh:

            def emit(rec):
                fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
                fh.flush()

            for url, body in raw_pages:
                emit(
                    archive.make_record(
                        "list", source, "__list__", url, utcnow(), 200, body
                    )
                )

            for i, ext in enumerate(targets, 1):
                try:
                    status_code, body, url = mod.fetch_model(session, ext)
                except mod.FetchError as exc:
                    failed += 1
                    notes.append(f"{ext}: {exc}")
                    print(f"[collect] FAIL {ext}: {exc}", file=sys.stderr)
                    continue
                emit(
                    archive.make_record(
                        "model", source, ext, url, utcnow(), status_code, body
                    )
                )
                recorded += 1
                if status_code in mod.ABSENT_STATUS:
                    gone += 1
                    print(f"[collect] ABSENT {ext}: HTTP {status_code}")
                if i % 100 == 0 or i == len(targets):
                    print(f"[collect] {i}/{len(targets)} recorded={recorded} failed={failed}")
                time.sleep(mod.REQUEST_PAUSE)

        # --- 4. freeze ---------------------------------------------------
        if not recorded:
            # Nothing to archive.  Do not leave an empty file behind that a
            # future reader could mistake for "we looked and found nothing".
            tmp.unlink(missing_ok=True)
            raise mod.FetchError(
                f"no responses recorded from {attempted} targets ({failed} failed)"
            )
        archive_rel, archive_sha, merkle, count = archive.archive_day(source, date, tmp)
        print(f"[archive] {archive_rel} ({count} records) sha256={archive_sha[:16]}… merkle={merkle[:16]}…")

        # --- 5. ingest ---------------------------------------------------
        inserted, skipped, dates = ingest_archive(con, source, archive_rel)
        if skipped:
            notes.append(f"{skipped} responses archived but unparseable")

        # --- 6. close the run --------------------------------------------
        if failed and not recorded:
            status = "failed"
        elif failed:
            status = "partial"
        else:
            status = "success"
        if gone:
            notes.append(f"{gone} targets no longer publicly reachable (recorded as absent)")

    except KeyboardInterrupt:
        notes.append("interrupted by operator")
        raise
    except Exception as exc:
        notes.append(f"{type(exc).__name__}: {exc}")
        print(f"[collect] ABORTED: {type(exc).__name__}: {exc}", file=sys.stderr)
        dates = []
    finally:
        # 铁律 4: a run never disappears silently, whatever happened above.
        finish_run(
            con,
            run_id,
            status,
            attempted=attempted,
            succeeded=recorded,
            failed=failed,
            archive_path=archive_rel,
            archive_sha256=archive_sha,
            merkle_root=merkle,
            error_note="; ".join(notes)[:4000] or None,
        )
        print(f"[run {run_id}] status={status} attempted={attempted} succeeded={recorded} failed={failed}")

    # --- 7/8. derived outputs -------------------------------------------
    rc = {"success": 0, "partial": 2}.get(status, 1)
    for d in dates or []:
        diff.compute(con, d, verbose=True)
        if publish:
            export.write_daily(con, d, verbose=True)
    if publish and status == "failed" and not dates:
        export.write_daily(con, date, verbose=True)  # record the gap in the open
    if not publish:
        print("[export] skipped: scratch --db does not rewrite data/daily/")
    con.close()
    return rc


# ----------------------------------------------------------------- replay --


def replay(source, target, db=None):
    """Rebuild database rows from frozen archives.  Never touches the network.

    Always inserts -- there is no "skip if already present" path, because a
    conditional insert is the first step towards a silent update (铁律 1).
    Replay into a fresh database (--db) when you want a clean rebuild.
    """
    publish = db is None
    con = connect(db)
    p = Path(target)
    paths = [p] if p.suffix == ".gz" and p.exists() else archive.find_archives(source, target)
    if not paths:
        print(f"[replay] no archive found for {source} {target}", file=sys.stderr)
        con.close()
        return 1
    total, dates = 0, set()
    for path in paths:
        n, _, ds = ingest_archive(con, source, path)
        total += n
        dates.update(ds)
    for d in sorted(dates):
        diff.compute(con, d, verbose=True)
        if publish:
            export.write_daily(con, d, verbose=True)
    if not publish:
        print("[export] skipped: scratch --db does not rewrite data/daily/")
    print(f"[replay] {total} observations from {len(paths)} archive(s)")
    con.close()
    return 0


# ------------------------------------------------------------------- main --


def main(argv=None):
    load_dotenv(ROOT / ".env")
    ap = argparse.ArgumentParser(prog="python -m src.collect")
    ap.add_argument("--source", default="huggingface", choices=sorted(SOURCES))
    ap.add_argument("--top", type=int, help="collect the N most downloaded models")
    ap.add_argument("--list", dest="listfile", help="file of model ids, one per line")
    ap.add_argument("--replay", metavar="DATE|PATH", help="rebuild from archives, offline")
    ap.add_argument("--db", help="database path (default db/modelpass.db)")
    args = ap.parse_args(argv)

    if args.replay:
        return replay(args.source, args.replay, args.db)
    if args.listfile:
        return collect(args.source, listfile=args.listfile, db=args.db)
    return collect(args.source, top=args.top or 1000, db=args.db)


if __name__ == "__main__":
    sys.exit(main())
