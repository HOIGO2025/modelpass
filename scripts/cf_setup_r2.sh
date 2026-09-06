#!/usr/bin/env bash
# Create the R2 bucket and its lock rule, from your own shell.
#
#   read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
#   scripts/cf_setup_r2.sh [bucket-name]
#
# The token is read from the environment, never from the command line: an
# argument is visible to every process on the machine via `ps`. Nothing here
# prints it, and nothing writes it to disk.
#
# What this does NOT do: create the S3 access key. That secret is shown once,
# in a response body, and it belongs in .env on the collection host and
# nowhere else -- so it stays a dashboard step. Everything else is automated.
#
# Idempotent: safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."

BUCKET="${1:-modelpass}"
API="https://api.cloudflare.com/client/v4"

# The script asks for the token itself rather than expecting you to chain
# `read -rs ... && ...` in front of it. A chain like that fails silently
# wherever stdin is not a terminal -- an editor's shell, a CI step, a `!`
# command in a coding agent -- because `read` hits EOF, returns 1, and the
# `&&` swallows everything after it. Nothing runs, nothing is printed.
TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [ -z "${TOKEN}" ] && [ -n "${CLOUDFLARE_API_TOKEN_FILE:-}" ]; then
    [ -r "${CLOUDFLARE_API_TOKEN_FILE}" ] \
        || { echo "cannot read ${CLOUDFLARE_API_TOKEN_FILE}" >&2; exit 1; }
    TOKEN="$(tr -d '\r\n' < "${CLOUDFLARE_API_TOKEN_FILE}")"
fi
if [ -z "${TOKEN}" ]; then
    if [ -t 0 ]; then
        printf 'Cloudflare API token (not echoed): ' >&2
        read -rs TOKEN < /dev/tty
        printf '\n' >&2
    else
        cat >&2 <<'EOF'
No token, and stdin is not a terminal so I cannot ask for one.

Run this in a real terminal:

    scripts/cf_setup_r2.sh

or supply it without typing it into a command line:

    CLOUDFLARE_API_TOKEN_FILE=~/.cf_token scripts/cf_setup_r2.sh

Do not pass the token as an argument: `ps` shows arguments to every
process on the machine.
EOF
        exit 1
    fi
fi
# Pasting picks up strays -- a trailing newline, a stray space, a zero-width
# character from a web page. Cloudflare rejects those with "Invalid format for
# Authorization header", which reads like a bad token rather than a bad paste.
TOKEN="$(printf '%s' "${TOKEN}" | tr -d '[:space:]')"
[ -n "${TOKEN}" ] || { echo "empty token" >&2; exit 1; }

# curl writes the body to one file and the status to another. The obvious
# `HTTP_STATUS=...` inside the function does not survive: every call site uses
# `$(cf ...)`, and a command substitution runs in a subshell, so the assignment
# is discarded before the caller ever sees it. Files cross that boundary.
BODY_FILE="$(mktemp)"
STATUS_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}" "${STATUS_FILE}"' EXIT

cf() {  # cf METHOD PATH [JSON]  -- body on stdout, status in STATUS_FILE
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS -X "${method}" "${API}${path}"
                -H "Authorization: Bearer ${TOKEN}")
    [ -n "${body}" ] && args+=(-H "Content-Type: application/json" --data "${body}")
    curl "${args[@]}" -w '%{http_code}' -o "${BODY_FILE}" > "${STATUS_FILE}" 2>/dev/null || true
    cat "${BODY_FILE}"
}

status() { cat "${STATUS_FILE}" 2>/dev/null || echo "000"; }

jqp() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

# python3 -c, not `python3 - <<HEREDOC`: with a heredoc Python reads the program
# from stdin, so a piped response never reaches json.load(sys.stdin) and every
# call reports "not JSON" whatever the API actually said. That false alarm is
# what this script produced on its first outing.
ok() {  # reads a response on stdin; prints why it failed, returns non-zero
    python3 -c '
import json, sys
label, st = sys.argv[1], sys.argv[2]
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:
    print(f"{label}: HTTP {st}, body was not JSON:", file=sys.stderr)
    print("  " + (raw[:300].replace(chr(10), " ") or "(empty)"), file=sys.stderr)
    raise SystemExit(1)
if d.get("success"):
    raise SystemExit(0)
print(f"{label}: HTTP {st}", file=sys.stderr)
for e in d.get("errors") or [{}]:
    chain = "; ".join(c.get("message", "") for c in (e.get("error_chain") or []))
    line = f"  {e.get('"'"'code'"'"', '"'"'?'"'"')} {e.get('"'"'message'"'"', '"'"'unknown error'"'"')}"
    print(line + (f" ({chain})" if chain else ""), file=sys.stderr)
raise SystemExit(1)
' "$1" "$(status)"
}

echo "== 1/3  finding the account =="
# Deliberately not /user/tokens/verify: that endpoint answers a different
# question (is this a valid user token) than the one that matters (can this
# token list accounts and touch R2). Let the first real call be the check.
ACCOUNTS="$(cf GET '/accounts?per_page=50')"
printf '%s' "${ACCOUNTS}" | ok "list accounts" || {
    echo "The token cannot list accounts. Check it was pasted whole, has not" >&2
    echo "expired, and includes account access." >&2
    exit 1
}
N="$(printf '%s' "${ACCOUNTS}" | jqp 'len(d["result"])')"
if [ "${N}" != "1" ]; then
    echo "  ${N} accounts on this token:"
    printf '%s' "${ACCOUNTS}" | jqp '"\n".join("    "+a["id"]+"  "+a["name"] for a in d["result"])'
    echo "  set CF_ACCOUNT_ID to the one you want and run again" >&2
    [ -n "${CF_ACCOUNT_ID:-}" ] || exit 1
fi
ACCOUNT_ID="${CF_ACCOUNT_ID:-$(printf '%s' "${ACCOUNTS}" | jqp 'd["result"][0]["id"]')}"
ACCOUNT_NAME="$(printf '%s' "${ACCOUNTS}" | jqp 'd["result"][0]["name"]')"
echo "  ${ACCOUNT_ID}  (${ACCOUNT_NAME})"

echo "== 2/3  creating bucket '${BUCKET}' =="
RESP="$(cf POST "/accounts/${ACCOUNT_ID}/r2/buckets" "{\"name\":\"${BUCKET}\"}" || true)"
if printf '%s' "${RESP}" | ok "create bucket" 2>/dev/null; then
    echo "  created"
else
    # 10004 = bucket already exists. Anything else is a real failure.
    if printf '%s' "${RESP}" | grep -q '"code":10004'; then
        echo "  already exists, leaving it alone"
    else
        printf '%s' "${RESP}" | ok "create bucket" || exit 1
    fi
fi

echo "== 3/3  locking the raw/ prefix, indefinitely =="
# Only raw/. The database snapshot at db/ is overwritten every day, and a
# whole-bucket lock would break it on the second day.
LOCK_BODY='{"rules":[{"id":"archives-forever","enabled":true,"prefix":"raw/","condition":{"type":"Indefinite"}}]}'
RESP="$(cf PUT "/accounts/${ACCOUNT_ID}/r2/buckets/${BUCKET}/lock" "${LOCK_BODY}" || true)"
printf '%s' "${RESP}" | ok "set bucket lock" || exit 1

VERIFY="$(cf GET "/accounts/${ACCOUNT_ID}/r2/buckets/${BUCKET}/lock")"
printf '%s' "${VERIFY}" | ok "read bucket lock" || exit 1
printf '%s' "${VERIFY}" | python3 -c '
import json, sys
rules = json.load(sys.stdin)["result"]["rules"]
for r in rules:
    print(f"  rule {r[\"id\"]}: prefix={r.get(\"prefix\",\"(whole bucket)\")!r} "
          f"enabled={r[\"enabled\"]} condition={r[\"condition\"][\"type\"]}")
if not any(r.get("prefix") == "raw/" for r in rules):
    print("  WARNING: no rule on the raw/ prefix", file=sys.stderr)
if any(not r.get("prefix") for r in rules):
    print("  WARNING: a whole-bucket rule exists; the daily database snapshot "
          "at db/ will start failing tomorrow", file=sys.stderr)
'

cat <<EOF

Done. Two values are still yours to fetch, because the secret is shown once:

  dashboard -> R2 -> Manage R2 API Tokens -> Create API Token
      Permissions:      Object Read & Write
      Specify buckets:  ${BUCKET}   (only this one -- a bucket-scoped token
                        can write but cannot remove the lock, which is the
                        whole reason the lock protects you)

Then, on the collection host:

  R2_REMOTE=r2:${BUCKET}
  RCLONE_CONFIG_R2_TYPE=s3
  RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  RCLONE_CONFIG_R2_REGION=auto
  RCLONE_CONFIG_R2_ENDPOINT=https://${ACCOUNT_ID}.r2.cloudflarestorage.com
  RCLONE_CONFIG_R2_ACCESS_KEY_ID=<Access Key ID>
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=<Secret Access Key>
EOF
