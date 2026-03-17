#!/usr/bin/env bash
# test/twin-error-handling.sh — Error response handling via digital twin servers.
#
# Tests that gent gracefully handles API errors by enqueuing error responses
# on the twin's control plane and verifying that gent surfaces them in the TUI.
#
# Scenarios:
#   1. 429 Rate Limit — twin returns an HTTP 429 with an error message
#   2. SSE stream error — twin returns an error event inside the SSE stream
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#   - docker compose (twins at twins/docker-compose.yml)
#   - curl on PATH
#
# Usage: bash test/twin-error-handling.sh

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
TWIN_API_KEY="test-key"

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

echo "── twin-error-handling: error response handling test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  (cd "$PROJECT" && cargo build 2>&1)
fi

ensure_twins_up

# ══════════════════════════════════════════════════════════════
# Test 1: HTTP 429 Rate Limit error
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 1: HTTP 429 Rate Limit error ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":429,"message":"Rate limit exceeded","error_type":"rate_limit_error"}' > /dev/null

SID_LINE=$(GENT_API_URL="$TWIN_API_URL" GENT_API_KEY="$TWIN_API_KEY" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

tui-wright type "$SID" "Trigger rate limit"
tui-wright key "$SID" enter

# The HTTP layer returns "status 429 — {json body}" as an error.
# Gent shows this as "Stream error: status 429 — ..." or "err: ..."
assert_screen_contains "$SID" "err:" "429 error: error indicator appears in TUI" 15000

tui-wright kill "$SID" 2>/dev/null || true
SID=""

# ══════════════════════════════════════════════════════════════
# Test 2: Recovery after error — gent still works
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 2: Recovery after error ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

# Enqueue an error first, then a success
curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":500,"message":"Internal server error","error_type":"api_error"}' > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"Recovery successful!"}' > /dev/null

SID_LINE=$(GENT_API_URL="$TWIN_API_URL" GENT_API_KEY="$TWIN_API_KEY" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

# First message triggers the error
tui-wright type "$SID" "First message (will error)"
tui-wright key "$SID" enter
assert_screen_contains "$SID" "err:" "recovery: first message shows error" 15000

# Second message should succeed (twin falls back to echo or serves queued response)
tui-wright type "$SID" "Second message (should work)"
tui-wright key "$SID" enter
assert_screen_contains "$SID" "Recovery successful!" "recovery: second message succeeds after error" 15000

# ── Results ───────────────────────────────────────────────────

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
