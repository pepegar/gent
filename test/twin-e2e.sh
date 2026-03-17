#!/usr/bin/env bash
# test/twin-e2e.sh — Full round-trip E2E test via digital twin servers.
#
# Verifies the complete HTTP path: gent → twin → streamed response → TUI.
# Enqueues a canned response on the Anthropic twin's control plane, sends a
# user message through gent, and asserts the response appears on screen and
# the request was captured by the twin.
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#   - docker compose (twins at twins/docker-compose.yml)
#   - curl and jq on PATH
#
# Usage: bash test/twin-e2e.sh

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

echo "── twin-e2e: full round-trip test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  (cd "$PROJECT" && cargo build 2>&1)
fi

# ── Ensure twins are running ──────────────────────────────────

ensure_twins_up

# ── Reset control plane ───────────────────────────────────────

echo "Resetting twin control plane..."
curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

# ── Enqueue a canned response ─────────────────────────────────

echo "Enqueuing text response: 'The answer is 42.'"
curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"The answer is 42."}' > /dev/null

# ── Spawn gent session ────────────────────────────────────────

echo "Spawning gent (${COLS}x${ROWS}) pointed at twin..."
SID_LINE=$(GENT_API_URL="$TWIN_API_URL" GENT_API_KEY="$TWIN_API_KEY" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

# ── Test 1: Submit a message and verify twin response appears ─

echo "Typing user message..."
tui-wright type "$SID" "What is the meaning of life?"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "The answer is 42." "twin response appears in TUI" 15000

# ── Test 2: Verify the twin captured the request ─────────────

echo "Checking twin request log..."
REQUESTS=$(curl -sf "$ANTHROPIC_TWIN/__control/requests")

if echo "$REQUESTS" | jq -e '.[0].body.messages[0].content' > /dev/null 2>&1; then
  USER_MSG=$(echo "$REQUESTS" | jq -r '.[0].body.messages[0].content')
  if [[ "$USER_MSG" == "What is the meaning of life?" ]]; then
    pass "twin captured correct user message"
  else
    fail "twin captured wrong user message: $USER_MSG"
  fi
else
  fail "twin request log is empty or malformed"
  echo "  Requests: $REQUESTS"
fi

# ── Test 3: Verify Anthropic headers were sent ────────────────

if echo "$REQUESTS" | jq -e '.[0].body.stream' > /dev/null 2>&1; then
  STREAM_FLAG=$(echo "$REQUESTS" | jq -r '.[0].body.stream')
  if [[ "$STREAM_FLAG" == "true" ]]; then
    pass "request has stream: true"
  else
    fail "request stream flag is not true: $STREAM_FLAG"
  fi
else
  fail "request body missing stream field"
fi

if echo "$REQUESTS" | jq -e '.[0].headers["anthropic-version"]' > /dev/null 2>&1; then
  ANTHRO_VER=$(echo "$REQUESTS" | jq -r '.[0].headers["anthropic-version"]')
  if [[ "$ANTHRO_VER" == "2023-06-01" ]]; then
    pass "anthropic-version header is correct"
  else
    fail "anthropic-version header is wrong: $ANTHRO_VER"
  fi
else
  fail "anthropic-version header missing"
fi

# ── Results ───────────────────────────────────────────────────

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
