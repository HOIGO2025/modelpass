"""SQLite plumbing.  No ORM, no migrations framework -- see CLAUDE.md.

The database is a derived artifact: everything in it can be rebuilt from
data/raw/ with `python -m src.collect --replay`.  The archives cannot be
rebuilt from anything.  Treat them accordingly.
"""
import os
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "db" / "schema.sql"
DEFAULT_DB = ROOT / "db" / "modelpass.db"


def db_path(explicit=None):
    if explicit:
        return Path(explicit)
    env = os.environ.get("MODELPASS_DB")
    if env:
        return Path(env)
    return DEFAULT_DB


def connect(path=None):
    """Open (creating and initialising if needed) the database."""
    p = db_path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(p), timeout=60)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    con.execute("PRAGMA journal_mode=WAL")
    have = con.execute(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='observations'"
    ).fetchone()[0]
    if not have:
        con.executescript(SCHEMA_PATH.read_text(encoding="utf-8"))
        con.commit()
    return con


def rel(path):
    """Repo-relative path string, so the DB stays portable across hosts."""
    p = Path(path).resolve()
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)
