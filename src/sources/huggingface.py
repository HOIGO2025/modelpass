"""HuggingFace Hub source adapter.

Three jobs, nothing else:
  list_targets()      -- decide which model ids to look at today
  fetch_model()       -- one HTTP GET, returns the bytes exactly as received
  parse_observation() -- turn one raw response into a row for `observations`

This module never opens the database and never writes a file.  It also
contains no analysis, no scoring, no opinions (铁律 5).
"""
import json
import os
import time

import requests

SOURCE = "huggingface"
API = "https://huggingface.co/api"
WEB = "https://huggingface.co"

PAGE_LIMIT = 1000          # hub caps a single page here
REQUEST_PAUSE = 0.3        # seconds between requests
TIMEOUT = 30               # seconds
MAX_TRIES = 3              # 1 attempt + 2 retries on transient failures
RETRY_STATUS = {429, 500, 502, 503, 504}

# Statuses that mean "we asked, and this model is not publicly there any
# more".  HuggingFace answers 401 -- not 404 -- for a repo that was
# deleted, turned private, or never existed: it refuses to confirm which.
# With HF_TOKEN set, a genuinely deleted repo answers 404 instead.
# Either way it is an observation of absence, not a fetch failure.
ABSENT_STATUS = (401, 403, 404, 410)

VERSION = "0.1"


class FetchError(RuntimeError):
    """A target we could not observe at all (network / server side)."""


def build_session(contact=None):
    contact = contact or os.environ.get("CONTACT_EMAIL") or "unset@example.com"
    s = requests.Session()
    s.headers.update(
        {
            "User-Agent": f"ModelPass/{VERSION} (open-model metadata time series; {contact})",
            "Accept": "application/json",
        }
    )
    token = os.environ.get("HF_TOKEN")
    if token:
        s.headers["Authorization"] = f"Bearer {token}"
    return s


def _get(session, url, params=None):
    """GET with bounded exponential backoff.

    Returns the requests.Response.  404/410 come back normally: "this model
    is gone" is a real observation, not a failure.  Raises FetchError only
    when we never got an answer worth recording.
    """
    last = None
    for attempt in range(1, MAX_TRIES + 1):
        try:
            resp = session.get(url, params=params, timeout=TIMEOUT)
            if resp.status_code in RETRY_STATUS and attempt < MAX_TRIES:
                wait = _retry_after(resp, attempt)
                last = f"HTTP {resp.status_code}"
                time.sleep(wait)
                continue
            if resp.status_code in RETRY_STATUS:
                raise FetchError(f"HTTP {resp.status_code} after {attempt} attempts: {url}")
            return resp
        except requests.RequestException as exc:
            last = f"{type(exc).__name__}: {exc}"
            if attempt >= MAX_TRIES:
                raise FetchError(f"{last} after {attempt} attempts: {url}") from exc
            time.sleep(2 ** (attempt - 1))
    raise FetchError(f"{last}: {url}")


def _retry_after(resp, attempt):
    raw = resp.headers.get("Retry-After")
    if raw:
        try:
            return min(float(raw), 60.0)
        except ValueError:
            pass
    return 2 ** (attempt - 1)


def list_targets(session, top):
    """Top-N model ids by download count, most downloaded first.

    Returns (ids, raw_pages) -- raw_pages are archived too: the ranking on a
    given day is itself part of the time series (铁律 2).
    """
    ids, raw_pages = [], []
    url = f"{API}/models"
    params = {
        "sort": "downloads",
        "direction": -1,
        "limit": min(top, PAGE_LIMIT),
        "full": "false",
    }
    while len(ids) < top:
        resp = _get(session, url, params=params)
        if resp.status_code != 200:
            raise FetchError(f"listing failed: HTTP {resp.status_code} {resp.url}")
        raw_pages.append((resp.url, resp.content))
        page = resp.json()
        if not page:
            break
        for item in page:
            mid = item.get("id") or item.get("modelId")
            if mid:
                ids.append(mid)
        nxt = _next_link(resp)
        if not nxt:
            break
        url, params = nxt, None
        time.sleep(REQUEST_PAUSE)
    return ids[:top], raw_pages


def _next_link(resp):
    link = resp.headers.get("Link")
    if not link:
        return None
    for part in link.split(","):
        bits = part.split(";")
        if len(bits) >= 2 and 'rel="next"' in bits[1].replace("'", '"'):
            return bits[0].strip().strip("<>")
    return None


def read_watchlist(path):
    ids = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                ids.append(line)
    return ids


def model_url(external_id):
    return f"{API}/models/{external_id}"


def source_url(external_id):
    return f"{WEB}/{external_id}"


def fetch_model(session, external_id):
    """Return (http_status, raw_bytes, url).  Raises FetchError if unanswered."""
    url = model_url(external_id)
    resp = _get(session, url)
    return resp.status_code, resp.content, url


# ---------------------------------------------------------------- parsing --

# NOTICE is deliberately absent: an Apache NOTICE file is attribution, not
# a licence grant, and has_license_file 1->0 is a high-severity signal.
_LICENSE_NAMES = ("COPYING",)


def _license_file(siblings):
    """The repo's licence file, if it ships one.

    Shallowest path first, then alphabetical, so a root LICENSE beats one
    buried in a subdirectory and the answer is deterministic.  Matching on
    "LICEN" anywhere in the filename catches MODEL_LICENSE, LICENSE.md,
    UNLICENSE and oddities like "dots.mocr LICENSE AGREEMENT", while still
    excluding NOTICE and THIRD_PARTY_NOTICES.
    """
    names = sorted(
        (s.get("rfilename", "") for s in siblings if s.get("rfilename")),
        key=lambda n: (n.count("/"), n),
    )
    for name in names:
        base = name.rsplit("/", 1)[-1].upper()
        if "LICEN" in base or base.split(".", 1)[0] in _LICENSE_NAMES:
            return name
    return None


def _as_text(value):
    """Store scalars as-is; anything structured as compact JSON."""
    if value is None or isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False, sort_keys=True)


def parse_observation(raw_text):
    """Raw response text -> dict of observation columns (no ids, no timestamps).

    Pure function of the archived bytes: re-runnable over data/raw/ forever,
    which is the whole point of keeping the raw responses (铁律 2).
    """
    d = json.loads(raw_text)
    card = d.get("cardData") or {}
    if not isinstance(card, dict):
        card = {}
    siblings = d.get("siblings") or []
    lic_path = _license_file(siblings)
    external_id = d.get("id") or d.get("modelId")
    return {
        "external_id": external_id,
        "source_url": source_url(external_id),
        "revision": d.get("sha"),
        "declared_license": _as_text(card.get("license")),
        "has_license_file": 1 if lic_path else 0,
        "license_file_path": lic_path,
        "downloads": d.get("downloads"),
        "likes": d.get("likes"),
        "pipeline_tag": d.get("pipeline_tag"),
        "base_model_ref": _as_text(card.get("base_model")),
        # 原样存 JSON 数组 -- order preserved, compact separators so that
        # string comparison in diff.py is stable.
        "tags_json": json.dumps(
            d.get("tags") or [], separators=(",", ":"), ensure_ascii=False
        ),
        # HuggingFace reports gated as false / "auto" / "manual".
        "is_gated": 1 if d.get("gated") else 0,
        "is_private": 1 if d.get("private") else 0,
        "last_modified": d.get("lastModified"),
    }
