# ModelPass

A daily collector that records how open AI model metadata changes over time.

The value here is not "which models exist" — anyone can scrape that this
afternoon. It is **when what changed**: the day a licence was rewritten, the
day a LICENSE file disappeared from a repo, the day a model became gated, the
day one quietly went away. That can only be accumulated, never back-filled.

**Series origin: 2026-09-04.** Every day after this is one more day that
cannot be reconstructed from anywhere else.

Read [CLAUDE.md](CLAUDE.md) before changing anything. It holds the five rules
the whole design serves.

---

## Quick start

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env          # then fill in CONTACT_EMAIL at minimum

python -m src.collect --source huggingface --top 20
```

That writes `data/raw/huggingface/{date}.jsonl.gz`, inserts observations into
`db/modelpass.db`, computes changes, and renders `data/daily/{date}.md`.

`.env` keys: `CONTACT_EMAIL` (goes in the User-Agent — be reachable),
`HF_TOKEN` (optional, higher rate limits), `ALERT_EMAIL`, `BACKUP_HOST`,
`MODELPASS_DB` (optional path override).

## Commands

```bash
# collect the 1000 most-downloaded models
python -m src.collect --source huggingface --top 1000

# collect a fixed watchlist instead
python -m src.collect --source huggingface --list config/watchlist.txt

# rebuild database rows from frozen archives — never touches the network
python -m src.collect --replay 2026-09-04
python -m src.collect --replay 2026-09-04 --db /tmp/rebuild.db   # into a scratch db

# recompute changes (derived; safe to redo any time)
python -m src.diff --date 2026-09-04
python -m src.diff --all

# daily summary + CSV dumps
python -m src.export --date 2026-09-04
python -m src.export --csv out/ --date 2026-09-04

# verify an archive against its manifest, independently of src/
python scripts/verify_merkle.py data/raw/huggingface/2026-09-04.jsonl.gz
python scripts/verify_merkle.py --all data/raw/huggingface
```

Exit codes for `collect`: **0** success · **1** failed · **2** partial.

## How a run works

1. open a `runs` row, `status='running'`
2. fetch the target list
3. fetch each model, appending the **raw response to disk immediately**
4. freeze the day's jsonl into `{date}.jsonl.gz` + `.manifest.json`, chmod 444
5. parse the **frozen archive** and INSERT entities + observations
6. close the `runs` row
7. `diff` — compare each observation with the previous one for that entity
8. `export` — render `data/daily/{date}.md`

Step 3 lands before anything is parsed, so a crash after it is fully
recoverable with `--replay`. Step 5 reads the `.gz` rather than the temp
file, so live collection and replay share exactly one code path — which is
what makes replay parity meaningful.

## Data model

`db/schema.sql`. Four tables:

| table | what it is | mutability |
|---|---|---|
| `entities` | one row per model: identity only, no state | insert-only |
| `observations` | **the asset.** one row per model per fetch | insert-only, never updated, never deleted |
| `changes` | derived by `diff.py` from `observations` | recomputed at will |
| `runs` | one row per collection attempt, success or not | the 铁律 4 ledger |

Identical values on consecutive days still produce a new observation row.
That is not waste: it is the evidence that nothing changed that day.

### Change severity

| severity | fields |
|---|---|
| `high` | `declared_license` changed · `has_license_file` 1→0 · `is_gated` 0→1 · model disappeared (`presence`) |
| `medium` | `base_model_ref`, `revision` |
| `low` | everything else (`downloads`, `likes`, `tags_json`, `pipeline_tag`, `last_modified`, …) |

"Adjacent observation" means the immediately preceding observation *of the
same entity* by `observed_at`, whatever day that was. Reruns, gaps and
back-filled replays all fall out of that definition without special cases.

This table is the only judgement in the system, and it lives in `diff.py`,
never in `observations` (铁律 5).

## Counting: succeeded, failed, absent

- **succeeded** — the hub answered and the response was archived.
- **failed** — no usable answer after 3 tries (timeout, connection error,
  5xx). The target is lost for that day.
- **absent** — the hub answered that the model is not publicly there. Counted
  under `succeeded`, noted in `runs.error_note`, and raised by `diff.py` as a
  `high` `presence` change **only if** we had observed that model before.

  HuggingFace answers **401**, not 404, for a repo that was deleted, turned
  private, or never existed — it declines to say which. With `HF_TOKEN` set, a
  genuinely deleted repo answers 404 instead. `ABSENT_STATUS` in
  `src/sources/huggingface.py` covers 401/403/404/410.

A model that merely fell out of today's top-N produces **no** presence change.
We never asked about it, so we learned nothing about it. Silence is not
evidence of disappearance.

## The archive

One gzipped jsonl per source per day (铁律 3), plus a manifest, both frozen at
`chmod 444`. A rerun on the same day gets `{date}.2.jsonl.gz`, `{date}.3…` —
the file is created with `O_EXCL`, so a frozen archive can never be clobbered.

What `444` actually buys, stated honestly: on a normal filesystem it stops
modification even by the file's owner — but not by `root`, and not deletion,
which the directory's write bit governs. So it is a guardrail against accident,
not a lock against intent. The real integrity guarantee is the hash chain: the
manifest pins every record's sha256, the archive's own sha256, and the Merkle
root, and `verify_merkle.py` recomputes all three from an independent
implementation. Run the collector as a non-root user (the container does) or
`444` means nothing at all.

One JSON object per line:

```json
{"kind": "model", "source": "huggingface", "external_id": "Qwen/Qwen3-32B",
 "url": "https://huggingface.co/api/models/Qwen/Qwen3-32B",
 "fetched_at": "2026-09-04T03:00:11Z", "http_status": 200,
 "raw_sha256": "…", "raw": "<response body, verbatim>"}
```

`raw` holds the body character-for-character, as a JSON *string* — never
re-serialised as an object, because that would silently rewrite key order and
number formatting. `raw_sha256` is taken over the original bytes off the wire,
so `sha256(raw.encode("utf-8"))` reproduces it. The listing responses are
archived too (`kind: "list"`): the day's ranking is itself time-series data.

Parsing can be redone from these files forever. That is the entire point of
keeping them (铁律 2).

### Merkle definition

```
leaf   = sha256(raw_response_bytes).hexdigest()   # file order, lowercase hex
parent = sha256((left_hex + right_hex).encode("utf-8")).hexdigest()
odd count at a level -> the last node is paired with itself
zero records         -> sha256(b"").hexdigest()
```

Implemented in `src/archive.py` and **re-implemented independently** in
`scripts/verify_merkle.py`, which imports nothing from `src/`. If the two ever
disagree, that is the check doing its job. Never change this definition
retroactively.

## Operations

Two cron entries. They must be separate: when `daily.sh` dies, the alert it
would have sent dies with it, so the staleness check has to be a different
process that only reads the database.

```cron
0 3 * * *  /opt/modelpass/scripts/daily.sh
17 * * * * /opt/modelpass/scripts/check_freshness.sh    # alerts after 25h with no success
0 5 * * 0  /opt/modelpass/scripts/verify.sh             # weekly restore drill
```

- `scripts/daily.sh` — collect → export → backup → publish. Any failure mails
  `ALERT_EMAIL`, and always leaves `logs/ALERT-{date}.txt` behind so the next
  freshness check trips too, even with no MTA on the box.
- `scripts/backup.sh` — `sqlite3 .backup` snapshot (never rsync a live SQLite
  file) plus `data/raw/`, to `BACKUP_HOST`. **Different provider, different
  region.** Same-provider backup protects against disk failure and nothing else.
- `scripts/verify.sh` — pulls a random day back *from the backup host*,
  re-verifies every hash and the Merkle root, then replays it into a throwaway
  database to prove the bytes are not just intact but usable. An unverified
  backup is not a backup.
- `scripts/publish.sh` — commits `data/daily/{date}.md` and the day's Merkle
  root, and pushes if an `origin` remote exists. Summaries and hashes only;
  raw archives never leave the collection host.

`.github/workflows/daily-commit.yml` cannot collect anything — the runner
cannot see the server's archives. It does two jobs: sanity-check each summary
as it arrives, and, on its own 06:00 UTC schedule, **fail loudly if today's
summary never showed up**. That red X is a second alarm, independent of the
server's mail path.

## Where this runs

Three layers, each doing the thing it is actually good at:

| layer | job | why there |
|---|---|---|
| an always-on host | **collect** | needs a reliable clock, a real filesystem, and 20 uninterrupted minutes a day |
| object storage elsewhere | **backup** | different provider, different region, zero egress on restore |
| GitHub | **witness** | third-party timestamp on the daily summary + Merkle root |

Two tempting options that are wrong for this project:

- **Cloudflare Workers as the collector.** A Worker gets 1000 subrequests per
  invocation on the paid plan (50 on free), and a 1000-model day needs exactly
  1000 — no headroom to ever watch more. It would also mean rewriting working
  Python as JS for a runtime whose execution model fights a 20-minute I/O loop.
  Trading the one thing that must never fail for a fashionable runtime is a bad
  trade. R2, on the other hand, is an excellent backup target — see `R2_REMOTE`.
- **GitHub Actions as the collector.** Scheduled workflows are delayed under
  load and are sometimes **dropped entirely**. A skipped day cannot be
  back-filled, which is the entire reason 铁律 4 exists. Actions stays where it
  belongs: witnessing what the collector already did.

## Docker

The image is disposable. The data is not.

```bash
cp .env.example .env        # fill in CONTACT_EMAIL, and a backup target
docker compose up -d --build
docker compose logs -f      # scheduler + run output
```

Set `UID`/`GID` to the host account that owns `./data` and `./db` (the compose
file defaults to 1000, which is `ubuntu` on most VPS images):

```bash
echo "MODELPASS_UID=$(id -u)" >> .env && echo "MODELPASS_GID=$(id -g)" >> .env
```

(Not `UID`/`GID`: the shell scripts `source .env`, and `UID` is readonly in
bash — assigning it would abort them under `set -e`.)

The container runs as that user, never as root — otherwise `chmod 444` on the
archives is decorative.

`docker-compose.yml` bind mounts `./data`, `./db` and `./logs` from the host.
Note that the host's `db/` is mounted at **`/app/state`**, not `/app/db`:
mounting over `/app/db` would hide the `schema.sql` that ships in the image and
every run would die creating its tables. The entrypoint checks for this at
startup rather than at 03:00.

On macOS Docker Desktop the bind mount cannot carry Unix permission bits, so
archives appear writable on the host side. That is a Docker Desktop artifact;
on a Linux host the `444` holds. Verified both ways.
**Never replace those with named volumes, and never run `docker compose down
-v` here** — the archive is the one thing in this project that cannot be
rebuilt from anything else. The entrypoint warns at startup if `/app/data` is
not a mount point.

The container schedules itself with a plain bash loop rather than a cron
daemon, for one reason cron cannot cover: **catch-up**. On every start it runs
`check_freshness.sh`, and if no successful run is on record it collects
immediately. A host that was rebooted, or a laptop that was asleep at 03:00,
therefore repairs the gap instead of silently skipping the day. `restart:
unless-stopped` covers reboots.

`RUN_AT_UTC` (default `03:00`) sets the daily time; `TOP` sets how many models.

Publishing to git happens on the host, not in the container — it needs the
repository and your credentials. `daily.sh` detects the absence of `.git` and
says so rather than failing. Run `scripts/publish.sh` from the host, e.g.:

```cron
30 4 * * * cd /path/to/modelpass && scripts/publish.sh $(date -u +\%F)
```

## Restore

```bash
scp backup:/archive/modelpass/huggingface/2026-09-04.* data/raw/huggingface/
python scripts/verify_merkle.py data/raw/huggingface/2026-09-04.jsonl.gz
python -m src.collect --replay 2026-09-04 --db db/rebuilt.db
```

The database is disposable — everything in it is rebuildable from `data/raw/`.
The archives are not rebuildable from anything. Back up accordingly.

`--replay` always inserts; there is no "skip if already present" path, because
a conditional insert is the first step toward a silent update (铁律 1). Replay
into a fresh `--db` when you want a clean rebuild. Each archive is ingested in
a single transaction, so a crash mid-ingest rolls back rather than leaving a
half-loaded day.

Any run given an explicit `--db` leaves `data/daily/` untouched. Only a run
against the real database may rewrite the committed public record, so a
restore drill can never overwrite the summary of the day it is checking.

Re-parsing is the reason the raw responses are kept. When the parser improves,
`--replay` into a fresh database rebuilds every past day with the new logic —
that is a correction, not a rewrite of history, because the bytes it reads
from are frozen and hash-verified.

## Self-check

```bash
grep -rn "DO UPDATE\|DELETE FROM observations" src/    # must print nothing
python scripts/verify_merkle.py --all data/raw/huggingface
sqlite3 db/modelpass.db "SELECT status, count(*) FROM runs GROUP BY status;"
```

## Layout

```
db/schema.sql            the four tables
src/collect.py           run orchestration, replay
src/archive.py           freeze + manifest + merkle
src/diff.py              adjacent-observation comparison, severity
src/export.py            daily markdown, CSV
src/db.py                connection helper (no ORM)
src/sources/huggingface.py   list / fetch / parse — one module per source
scripts/                 cron, backup, restore drill, standalone verifier
data/raw/                archives (gitignored, backed up)
data/daily/              summaries (committed — the public record)
```

Adding a source means one new module in `src/sources/` exposing
`build_session`, `list_targets`, `read_watchlist`, `fetch_model`,
`parse_observation`, `ABSENT_STATUS`, `REQUEST_PAUSE`, `FetchError`, and one
line in `SOURCES` in `src/collect.py`.

## Manners

0.3 s between requests, 30 s timeout, 3 tries with exponential backoff,
`Retry-After` honoured, 404 never retried, and a User-Agent that names the
project and a contact address. One model failing never stops the run.
