#!/usr/bin/env python3
"""Standalone archive verifier.  Imports nothing from src/ on purpose.

If this script and src/archive.py ever disagree, that is the point: an
independent re-implementation is the only kind of check worth having.

    python scripts/verify_merkle.py data/raw/huggingface/2026-09-04.jsonl.gz
    python scripts/verify_merkle.py --all data/raw/huggingface

Checks, in order:
  1. every record's raw_sha256 really is sha256 of its stored raw body
  2. the merkle root rebuilt from those leaves matches the manifest
  3. the manifest's archive_sha256 matches the .gz on disk
  4. the manifest record count matches the file
  5. the archive and manifest are read-only (reported, but not an integrity
     failure -- a restored copy or a mount that cannot carry modes is a
     storage caveat, not evidence of tampering)

Merkle definition:
  leaf   = sha256(raw_bytes).hexdigest(), file order, lowercase hex
  parent = sha256((left_hex + right_hex).encode("utf-8")).hexdigest()
  odd count at a level -> last node paired with itself
  no records           -> sha256(b"").hexdigest()

Exit 0 if everything checks out, 1 otherwise.
"""
import argparse
import gzip
import hashlib
import json
import os
import sys


def merkle_root(leaves):
    if not leaves:
        return hashlib.sha256(b"").hexdigest()
    level = list(leaves)
    while len(level) > 1:
        if len(level) % 2:
            level.append(level[-1])
        level = [
            hashlib.sha256((level[i] + level[i + 1]).encode("utf-8")).hexdigest()
            for i in range(0, len(level), 2)
        ]
    return level[0]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify(archive_path):
    problems = []
    manifest_path = archive_path[: -len(".jsonl.gz")] + ".manifest.json"
    if not os.path.exists(manifest_path):
        return [f"missing manifest: {manifest_path}"], [], 0
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    leaves, n = [], 0
    try:
        with gzip.open(archive_path, "rt", encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                if not line.strip():
                    continue
                rec = json.loads(line)
                n += 1
                actual = hashlib.sha256(rec["raw"].encode("utf-8")).hexdigest()
                if actual != rec["raw_sha256"]:
                    problems.append(
                        f"line {lineno} ({rec.get('external_id')}): raw_sha256 "
                        f"{rec['raw_sha256'][:16]}… but body hashes to {actual[:16]}…"
                    )
                leaves.append(actual)
    except (OSError, gzip.BadGzipFile, UnicodeDecodeError, json.JSONDecodeError) as exc:
        # Damaged, truncated or appended-to: report it, do not crash.  This is
        # the failure this script exists to find.
        problems.append(f"archive unreadable at record {n + 1}: {type(exc).__name__}: {exc}")
        return problems, [], n

    root = merkle_root(leaves)
    if root != manifest.get("merkle_root"):
        problems.append(
            f"merkle root {root} != manifest {manifest.get('merkle_root')}"
        )
    file_sha = sha256_file(archive_path)
    if file_sha != manifest.get("archive_sha256"):
        problems.append(
            f"archive sha256 {file_sha} != manifest {manifest.get('archive_sha256')}"
        )
    if n != manifest.get("count"):
        problems.append(f"record count {n} != manifest {manifest.get('count')}")
    manifest_leaves = [r["raw_sha256"] for r in manifest.get("records", [])]
    if manifest_leaves != leaves:
        problems.append("manifest record list does not match the archive contents")
    warnings = []
    for p in (archive_path, manifest_path):
        if os.access(p, os.W_OK) and os.geteuid() != 0:
            warnings.append(f"not read-only: {p}")
    return problems, warnings, n


def main(argv=None):
    ap = argparse.ArgumentParser(prog="verify_merkle.py")
    ap.add_argument("target", help="an archive .jsonl.gz, or a directory with --all")
    ap.add_argument("--all", action="store_true", help="verify every archive in a directory")
    args = ap.parse_args(argv)

    if args.all:
        targets = sorted(
            os.path.join(args.target, f)
            for f in os.listdir(args.target)
            if f.endswith(".jsonl.gz")
        )
    else:
        targets = [args.target]
    if not targets:
        print("no archives found", file=sys.stderr)
        return 1

    bad = 0
    for t in targets:
        problems, warnings, n = verify(t)
        if problems:
            bad += 1
            print(f"FAIL {t} ({n} records)")
            for p in problems:
                print(f"     - {p}")
        else:
            print(f"OK   {t} ({n} records)")
        for w in warnings:
            print(f"     ! {w}")
    if bad:
        print(f"\n{bad}/{len(targets)} archive(s) FAILED verification", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
