#!/usr/bin/env bash
# test/twin-auth.sh — Authentication verification via digital twin servers.
#
# Tests two scenarios:
#   1. Valid API key — twin accepts the request and gent shows the response.
#      Verifies the authorization header is correctly sent.
#   2. Invalid API key — twin returns 401 and gent shows an error.
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#   - docker compose (twins at twins/docker-compose.yml)
#   - curl and jq on PATH
#
# Usage: bash test/twin-auth.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"

GENT="$PROJECT/target/debug/gent"
COLS=120
ROWS=30
PASS=0
FAIL=0

ANTHROPIC_TWIN="http://localhost:18080"
TWIN_API_URL="$ANTHROPIC_TWIN/v1/messages"

SID=""

# ── Helpers ───────────────────────────────────────────────────

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

assert_screen_contains() {
  local sid="$1"
  local expected="$2"
  local label="$3"
  local timeout="${4:-15000}"
  if tui-wright wait-for "$sid" "$expected" --timeout "$timeout" > /dev/null 2>&1; then
    pass "$label"
  else
    echo "  Screen contents:"
    tui-wright screen "$sid" 2>/dev/null | tail -15
    fail "$label (expected '$expected')"
  fi
}

cleanup() {
  if [[ -n "$SID" ]]; then
    tui-wright kill "$SID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

ensure_twins_up() {
  if curl -sf "$ANTHROPIC_TWIN/__control/health" > /dev/null 2>&1; then
    echo "Anthropic twin already healthy."
    return
  fi
  echo "Starting twin containers..."
  docker compose -f "$PROJECT/twins/docker-compose.yml" up -d --wait
  for i in $(seq 1 15); do
    if curl -sf "$ANTHROPIC_TWIN/__control/health" > /dev/null 2>&1; then
      echo "Anthropic twin is healthy."
      return
    fi
    sleep 1
  done
  echo "FATAL: Anthropic twin did not become healthy"
  exit 1
}

# ── Build ─────────────────────────────────────────────────────

echo "── twin-auth: authentication verification test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  (cd "$PROJECT" && cargo build 2>&1)
fi

ensure_twins_up

# ══════════════════════════════════════════════════════════════
# Test Part 1: Valid API key
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Part 1: Valid API key ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"Auth check passed."}' > /dev/null

# The twin's default auth_keys is ["test-key"], and gent sends
# "authorization: Bearer <key>" for non-default Anthropic URLs.
SID_LINE=$(GENT_API_URL="$TWIN_API_URL" GENT_API_KEY="test-key" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

tui-wright type "$SID" "Hello twin"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "Auth check passed." "valid key: twin response appears" 15000

REQUESTS=$(curl -sf "$ANTHROPIC_TWIN/__control/requests")

# Gent uses "authorization: Bearer <key>" for custom URLs (non-default Anthropic endpoint)
if echo "$REQUESTS" | jq -e '.[0].headers.authorization' > /dev/null 2>&1; then
  AUTH_HEADER=$(echo "$REQUESTS" | jq -r '.[0].headers.authorization')
  if [[ "$AUTH_HEADER" == "Bearer test-key" ]]; then
    pass "valid key: authorization header contains correct key"
  else
    fail "valid key: authorization header is wrong: $AUTH_HEADER"
  fi
else
  fail "valid key: authorization header missing from request"
  echo "  Headers: $(echo "$REQUESTS" | jq '.[0].headers')"
fi

tui-wright kill "$SID" 2>/dev/null || true
SID=""

# ══════════════════════════════════════════════════════════════
# Test Part 2: Invalid API key (401 rejection)
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Part 2: Invalid API key ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

SID_LINE=$(GENT_API_URL="$TWIN_API_URL" GENT_API_KEY="wrong-key" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

tui-wright type "$SID" "This should fail"
tui-wright key "$SID" enter

# Gent should show an error containing "401" or "authentication" or "Stream error"
# The HTTP layer reports "status 401 — {body}" which becomes "Stream error: status 401 — ..."
assert_screen_contains "$SID" "err:" "invalid key: error indicator appears in TUI" 15000

# ── Results ───────────────────────────────────────────────────

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
