#!/usr/bin/env python3
"""Print the Merkle roots archived for one date, for the commit message.

Reads the manifests, not the database: the manifest is the authoritative
record of what was archived, and this keeps scripts/publish.sh -- the one
script that has to run on the host rather than in the container -- free of
any sqlite3 dependency.
"""
import glob
import json
import sys


def main(date):
    roots = []
    paths = sorted(
        glob.glob(f"data/raw/*/{date}.manifest.json")
        + glob.glob(f"data/raw/*/{date}.[0-9]*.manifest.json")
    )
    for path in paths:
        try:
            with open(path, encoding="utf-8") as fh:
                m = json.load(fh)
        except (OSError, ValueError):
            continue
        root = m.get("merkle_root")
        if root:
            roots.append(f"{m.get('source', '?')}/{m.get('archive', '?')}={root}")
    print(" ".join(roots) if roots else "none")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ""))
