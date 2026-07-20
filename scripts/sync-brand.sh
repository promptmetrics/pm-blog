#!/bin/sh
# Auto-sync BRAND.md from a user-supplied private git repo into the plugin
# data dir. Read-only (repo -> machine), idempotent, non-blocking on
# failure. Adapted from izzy-blog-cowork's sync-personas.sh (same lock/TTL/
# auth/atomic-write machinery); this variant syncs a single markdown file
# instead of a directory of persona JSON, so there is no mirror/delete mode.
#
# The plugin ships NO repo hardcoded. The user supplies repo/branch/auth via
# ${CLAUDE_PLUGIN_DATA}/brand-sync.json (copied from the template on first
# run). Empty repo => warn-once + skip + continue.
#
# On any failure this script prints a warning to stderr (and an append-only
# log) and exits 0 -- the blog orchestrator must continue with whatever
# BRAND.md already exists locally (or none at all).
set -u

DATA="${CLAUDE_PLUGIN_DATA:-}"
ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# All failure paths exit 0 so the pipeline never breaks on sync failure.
exit0() { exit 0; }

if [ -z "$DATA" ] || [ -z "$ROOT" ]; then
  echo "sync-brand: CLAUDE_PLUGIN_DATA/CLAUDE_PLUGIN_ROOT unset -- skipping" >&2
  exit0
fi

# python3 (stdlib only) is used for JSON parsing and BRAND.md shape
# validation. jq is not assumed available. If python3 is missing, we cannot
# parse config or validate the synced file, so skip silently.
if ! command -v python3 >/dev/null 2>&1; then
  echo "sync-brand: python3 not on PATH -- skipping" >&2
  exit0
fi

LOG="$DATA/.brand-sync.log"
# Cap the log at ~1 MB (truncate-on-open when over the cap).
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')" -gt 1048576 ]; then
  : > "$LOG" 2>/dev/null || true
fi
log() { echo "$(date -u +%FT%TZ) $*" >>"$LOG" 2>/dev/null || true; }
warn() { echo "sync-brand: $*" >&2; log "WARN $*"; }

# ---------------------------------------------------------------------------
# STEP 1 -- Load config. Copy the template into the data dir on first run.
# ---------------------------------------------------------------------------
CFG="$DATA/brand-sync.json"
TPL="$ROOT/scripts/brand-sync.example.json"
if [ ! -f "$TPL" ]; then
  warn "template brand-sync.example.json missing -- skipping"
  exit0
fi
if [ ! -f "$CFG" ]; then
  cp "$TPL" "$CFG" 2>/dev/null || { warn "cannot write $CFG -- skipping"; exit0; }
  log "seeded config from template"
fi

# Validate the config is well-formed JSON up front so a typo doesn't masquerade
# as an "empty repo" warning.
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CFG" 2>/dev/null; then
  warn "brand-sync.json is malformed JSON -- skipping (fix the syntax and rerun)"
  exit0
fi

# Parse a config key via python3 stdlib. Booleans are coerced to lowercase
# "true"/"false" so shell string compares are case-correct; JSON null and
# missing keys become the empty string. Exits non-zero on a malformed file
# (already validated above, so this is defense-in-depth).
parse_cfg() {  # $1 = key
  python3 - "$CFG" "$1" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict):
    print(''); sys.exit(0)
k = sys.argv[2]
v = d.get(k, '')
if isinstance(v, bool):
    print('true' if v else 'false')
elif v is None:
    print('')
else:
    print(v)
PY
}

enabled=$(parse_cfg enabled)
if [ "$enabled" = "false" ]; then
  log "disabled via config"
  exit0
fi

repo=$(parse_cfg repo)
branch=$(parse_cfg branch); [ -z "$branch" ] && branch=main
auth=$(parse_cfg auth);    [ -z "$auth" ]   && auth=auto
ttl=$(parse_cfg ttl_seconds); [ -z "$ttl" ] && ttl=900
# Sanitize ttl to a positive integer.
case "$ttl" in *[!0-9]*) ttl=900;; esac
[ "$ttl" -lt 1 ] && ttl=900

# ---------------------------------------------------------------------------
# STEP 2 -- Empty repo => warn-once + skip.
# ---------------------------------------------------------------------------
if [ -z "$repo" ]; then
  WARNED="$DATA/.brand-sync-no-repo-warned"
  if [ ! -f "$WARNED" ]; then
    warn "brand-sync.json has empty 'repo' -- set it to 'owner/name' to enable. Skipping."
    : > "$WARNED" 2>/dev/null || true
  fi
  exit0
fi
rm -f "$DATA/.brand-sync-no-repo-warned" 2>/dev/null || true

# ---------------------------------------------------------------------------
# STEP 3 -- TTL skip. Exit silently if the cache was refreshed recently.
# ---------------------------------------------------------------------------
LAST="$DATA/.brand-sync-last"
now=$(date +%s 2>/dev/null || echo 0)
# If we can't read the clock, don't risk a bogus "fresh" decision -- run sync.
if [ "$now" -gt 0 ] && [ -f "$LAST" ]; then
  last=$(cat "$LAST" 2>/dev/null)
  case "$last" in *[!0-9]*) last=0;; esac
  delta=$((now - last))
  if [ "$delta" -ge 0 ] && [ "$delta" -lt "$ttl" ]; then
    exit0
  fi
fi

# ---------------------------------------------------------------------------
# STEP 4 -- Acquire a mkdir-based lock (atomic on macOS; no flock needed).
# Stale after 300s. A lock dir with no .ts is treated as stale (age = infinity)
# so a crashed run never wedges all future syncs.
# ---------------------------------------------------------------------------
CACHE="$DATA/.brand-cache"
LOCK="$CACHE/.lock"
mkdir -p "$CACHE" 2>/dev/null || true
acquired=0
if mkdir "$LOCK" 2>/dev/null; then
  acquired=1
else
  if [ -f "$LOCK/.ts" ]; then
    lts=$(cat "$LOCK/.ts" 2>/dev/null)
    case "$lts" in *[!0-9]*) lts=0;; esac
    [ "$((now - lts))" -gt 300 ] && lts=0  # force stale reclaim below
  else
    lts=0  # no .ts => treat as ancient/stale
  fi
  if [ "$lts" -eq 0 ]; then
    rm -rf "$LOCK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
      acquired=1
    fi
  fi
fi
if [ "$acquired" != 1 ]; then
  warn "another sync is running (lock held) -- skipping"
  exit0
fi
date +%s > "$LOCK/.ts" 2>/dev/null || true
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

# ---------------------------------------------------------------------------
# STEP 5 -- Resolve auth. Build a CLEAN remote URL (no embedded token) plus a
# bearer/basic token when applicable. The token is never placed in the URL or
# in .git/config; it is passed per-invocation via http.extraHeader.
# Priority: gh > pat > ssh (unless auth forces one). none => public https.
# ---------------------------------------------------------------------------
tok=""
remote_url=""
case "$auth" in
  gh|pat|ssh|none) mode=$auth ;;
  *) mode=auto ;;
esac

if [ "$mode" = auto ] || [ "$mode" = gh ]; then
  if command -v gh >/dev/null 2>&1; then
    t=$(gh auth token 2>/dev/null) || t=""
    if [ -n "$t" ]; then
      tok=$t
      remote_url="https://github.com/${repo}.git"
    fi
  fi
  [ -z "$tok" ] && [ "$mode" = gh ] && warn "gh not authed -- no fallback under auth=gh"
fi

if [ -z "$tok" ] && { [ "$mode" = auto ] || [ "$mode" = pat ]; }; then
  ENVF="$DATA/brand-sync.env"
  if [ -f "$ENVF" ]; then
    t=$(
      umask 077
      . "$ENVF" 2>/dev/null && printf '%s' "${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    )
    if [ -n "$t" ]; then
      tok=$t
      remote_url="https://github.com/${repo}.git"
    fi
  fi
  [ -z "$tok" ] && [ "$mode" = pat ] && warn "PAT not found in $ENVF"
fi

if [ -z "$tok" ] && { [ "$mode" = auto ] || [ "$mode" = ssh ]; }; then
  remote_url="git@github.com:${repo}.git"
fi

if [ -z "$tok" ] && [ -z "$remote_url" ] && [ "$mode" = none ]; then
  remote_url="https://github.com/${repo}.git"
fi

if [ -z "$remote_url" ]; then
  warn "no auth method resolved -- skipping"
  exit0
fi

# Encode the token for a Basic-auth http header (base64 via python3 stdlib).
# The remote URL stays clean (no embedded token, nothing in .git/config); this
# header is passed per git invocation only, so subsequent `fetch` runs keep
# working. The header value contains a space, so it must reach git as a SINGLE
# argument -- we pass it via positional parameters ($@), never word-split.
auth_header=""
if [ -n "$tok" ]; then
  b64=$(printf 'x-access-token:%s' "$tok" | python3 -c "import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())" 2>/dev/null) || b64=""
  if [ -z "$b64" ]; then
    warn "could not encode auth token -- skipping"
    exit0
  fi
  auth_header="Authorization: Basic $b64"
fi
# Never echo the token to logs/stderr.
log "resolved auth, target repo=$repo branch=$branch"

# ---------------------------------------------------------------------------
# STEP 6 -- Clone or fetch, shallow + branch-pinned.
# credential.helper= disables any default helper (no hung macOS Keychain
# prompt); core.fsmonitor=false avoids a one-shot fsmonitor daemon spawn.
# $GIT_OPTS word-splits safely (no spaces inside values); the optional auth
# header is injected via "$@" so its space survives intact.
# ---------------------------------------------------------------------------
GIT_OPTS="-c credential.helper= -c core.fsmonitor=false"
if [ -d "$CACHE/.git" ]; then
  if [ -n "$auth_header" ]; then
    set -- -c "http.extraHeader=$auth_header"
  else
    set --
  fi
  if git $GIT_OPTS "$@" -C "$CACHE" fetch --depth 1 origin "$branch" >>"$LOG" 2>&1; then
    git $GIT_OPTS "$@" -C "$CACHE" reset --hard FETCH_HEAD >>"$LOG" 2>&1 || {
      warn "reset --hard failed -- using existing cache"
    }
  else
    warn "fetch failed (offline, branch renamed, or auth) -- re-cloning from scratch"
    rm -rf "$CACHE" 2>/dev/null
    if [ -n "$auth_header" ]; then
      set -- -c "http.extraHeader=$auth_header"
    else
      set --
    fi
    if git $GIT_OPTS "$@" clone --depth 1 --branch "$branch" "$remote_url" "$CACHE" >>"$LOG" 2>&1; then
      :
    else
      [ -d "$CACHE/.git" ] || { warn "clone failed -- skipping (no cache available)"; exit0; }
      warn "re-clone failed -- using whatever cache remains"
    fi
  fi
else
  if [ -n "$auth_header" ]; then
    set -- -c "http.extraHeader=$auth_header"
  else
    set --
  fi
  if git $GIT_OPTS "$@" clone --depth 1 --branch "$branch" "$remote_url" "$CACHE" >>"$LOG" 2>&1; then
    :
  else
    [ -d "$CACHE/.git" ] || { warn "clone failed -- skipping (offline or no access)"; exit0; }
    warn "clone failed (offline?) -- using existing cache if any"
  fi
fi

# ---------------------------------------------------------------------------
# STEP 7 -- Locate BRAND.md at the cache root.
# ---------------------------------------------------------------------------
SRC="$CACHE/BRAND.md"
if [ ! -f "$SRC" ]; then
  warn "no BRAND.md at repo root -- nothing to sync"
  date +%s > "$LAST" 2>/dev/null || true
  exit0
fi

# ---------------------------------------------------------------------------
# STEP 8 -- Validate shape (non-empty, UTF-8, no NUL bytes, <300KB) and
# atomically copy into place. A malformed payload is rejected and the prior
# good local copy (if any) is kept untouched.
# ---------------------------------------------------------------------------
DEST="$DATA/BRAND.md"
if python3 - "$SRC" <<'PY' 2>/dev/null
import sys
data = open(sys.argv[1], "rb").read()
if len(data) == 0:
    sys.exit(1)
if len(data) >= 300 * 1024:
    sys.exit(1)
if b"\x00" in data:
    sys.exit(1)
try:
    data.decode("utf-8")
except UnicodeDecodeError:
    sys.exit(1)
sys.exit(0)
PY
then
  tmp="$DATA/.BRAND.md.tmp.$$"
  if cp "$SRC" "$tmp" 2>/dev/null && mv "$tmp" "$DEST" 2>/dev/null; then
    log "synced BRAND.md repo=$repo branch=$branch"
  else
    rm -f "$tmp" 2>/dev/null || true
    warn "copy failed -- keeping prior BRAND.md if any"
  fi
else
  warn "BRAND.md failed shape validation (empty, >300KB, NUL byte, or not UTF-8) -- keeping prior copy if any"
fi

# ---------------------------------------------------------------------------
# STEP 9 -- Freshness marker. Written once we reached the clone/fetch step.
# ---------------------------------------------------------------------------
date +%s > "$LAST" 2>/dev/null || true
log "done repo=$repo"
exit0
