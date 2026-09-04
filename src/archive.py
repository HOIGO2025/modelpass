"""Pack one day's raw responses into a single read-only file (铁律 2 & 3).

One file per source per day -- not one per model.  Small files cost real
money on object storage and make the archive miserable to manage.

MERKLE DEFINITION (re-implemented independently in scripts/verify_merkle.py;
if you change it here, change it there, and never retroactively):

    leaf_i = sha256(raw_response_bytes_i).hexdigest()
             taken in jsonl line order, lowercase hex
    parent = sha256((left_hex + right_hex).encode("utf-8")).hexdigest()
    odd count at any level -> the last node is paired with itself
    zero records            -> sha256(b"").hexdigest()

ARCHIVE RECORD FORMAT -- one JSON object per line:

    {"kind": "model" | "list",
     "source": "...", "external_id": "...", "url": "...",
     "fetched_at": "2026-09-04T03:00:11Z", "http_status": 200,
     "raw_sha256": "...", "raw": "<response body, verbatim>"}

`raw` holds the response body character-for-character.  It is stored as a
JSON *string*, never as a re-serialised object, because re-serialising would
silently rewrite key order and number formatting.  raw_sha256 is taken over
the original bytes off the wire, so sha256(raw.encode("utf-8")) reproduces it.
"""
import gzip
import hashlib
import json
import os
import stat
from pathlib import Path

from .db import ROOT, rel

RAW_DIR = ROOT / "data" / "raw"
EMPTY_ROOT = hashlib.sha256(b"").hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def merkle_root(leaves):
    """Build the root from a list of lowercase hex leaf digests."""
    if not leaves:
        return EMPTY_ROOT
    level = list(leaves)
    while len(level) > 1:
        if len(level) % 2:
            level.append(level[-1])
        level = [
            hashlib.sha256((level[i] + level[i + 1]).encode("utf-8")).hexdigest()
            for i in range(0, len(level), 2)
        ]
    return level[0]


def make_record(kind, source, external_id, url, fetched_at, http_status, raw_bytes):
    """Envelope one response.  Raw body kept verbatim; nothing is dropped."""
    return {
        "kind": kind,
        "source": source,
        "external_id": external_id,
        "url": url,
        "fetched_at": fetched_at,
        "http_status": http_status,
        "raw_sha256": sha256_bytes(raw_bytes),
        "raw": raw_bytes.decode("utf-8"),
    }


def temp_path(source, date, run_id):
    d = RAW_DIR / source
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{date}.run{run_id}.jsonl"


def _pick_archive_path(source, date):
    """`{date}.jsonl.gz`, then `{date}.2.jsonl.gz`, ... -- never overwrite."""
    d = RAW_DIR / source
    d.mkdir(parents=True, exist_ok=True)
    candidate = d / f"{date}.jsonl.gz"
    n = 1
    while candidate.exists():
        n += 1
        candidate = d / f"{date}.{n}.jsonl.gz"
    return candidate


def manifest_path_for(archive_path):
    p = Path(archive_path)
    return p.with_name(p.name[: -len(".jsonl.gz")] + ".manifest.json")


def archive_day(source, date, tmp_path, keep_temp=False):
    """Compress the day's jsonl, write the manifest, freeze both.

    Returns (relative_archive_path, archive_sha256, merkle_root, count).
    """
    tmp_path = Path(tmp_path)
    records, leaves = [], []

    archive_path = _pick_archive_path(source, date)
    # O_EXCL: a frozen (444) archive can never be clobbered by a rerun.
    fd = os.open(str(archive_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    # Streamed a line at a time: a day's responses must never have to fit in
    # memory, however many models we end up watching.
    with os.fdopen(fd, "wb") as fh:
        # mtime=0 -> byte-identical output for identical input, so the
        # archive sha256 is reproducible.
        with gzip.GzipFile(filename="", mode="wb", fileobj=fh, mtime=0) as gz:
            with open(tmp_path, "r", encoding="utf-8") as src:
                for line in src:
                    if not line.strip():
                        continue
                    rec = json.loads(line)
                    leaves.append(rec["raw_sha256"])
                    records.append(
                        {
                            "kind": rec.get("kind", "model"),
                            "external_id": rec["external_id"],
                            "http_status": rec["http_status"],
                            "raw_sha256": rec["raw_sha256"],
                        }
                    )
                    if not line.endswith("\n"):
                        line += "\n"
                    gz.write(line.encode("utf-8"))

    root = merkle_root(leaves)
    archive_sha = sha256_file(archive_path)
    manifest = {
        "source": source,
        "date": date,
        "archive": archive_path.name,
        "count": len(records),
        "archive_sha256": archive_sha,
        "merkle_root": root,
        "merkle_spec": (
            "leaf=sha256(raw_bytes) hex in file order; "
            "parent=sha256(left_hex+right_hex); odd node paired with itself; "
            "empty=sha256(b'')"
        ),
        "records": records,
    }
    mpath = manifest_path_for(archive_path)
    with open(mpath, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    freeze(archive_path)
    freeze(mpath)
    if not keep_temp:
        tmp_path.unlink(missing_ok=True)
    return rel(archive_path), archive_sha, root, len(records)


def freeze(path):
    """Read-only for everyone.  An archive is evidence, not a scratch file."""
    os.chmod(path, stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)


def read_archive(path):
    """Yield the records of an archive, in file order."""
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                yield json.loads(line)


def load_manifest(archive_path):
    p = manifest_path_for(ROOT / archive_path if not Path(archive_path).is_absolute() else archive_path)
    if not p.exists():
        return None
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def find_archives(source, date):
    """All archives for a source/day, in creation order."""
    d = RAW_DIR / source
    if not d.exists():
        return []
    first = d / f"{date}.jsonl.gz"
    rest = sorted(
        p for p in d.glob(f"{date}.*.jsonl.gz") if p.name != f"{date}.jsonl.gz"
    )
    rest.sort(key=lambda p: int(p.name[len(date) + 1 :].split(".")[0]))
    return ([first] if first.exists() else []) + rest
