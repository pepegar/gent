#!/usr/bin/env bash
# test/twin-crossreview.sh — E2E test for /crossreview via digital twin servers.
#
# Verifies that /crossreview sends the latest exchange to the other provider
# and renders the review response with the correct visual treatment.
#
# Flow:
#   1. Start gent with Anthropic twin as active provider
#   2. Configure OpenAI twin URL + key via -l init file
#   3. Send a user message → get Anthropic twin response
#   4. Run /crossreview → should call OpenAI twin
#   5. Assert the OpenAI review text appears on screen
#   6. Verify the OpenAI twin received the cross-review request
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#   - docker compose (twins at twins/docker-compose.yml)
#   - curl and jq on PATH
#
# Usage: bash test/twin-crossreview.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"

GENT="$PROJECT/target/debug/gent"
COLS=120
ROWS=40
PASS=0
FAIL=0

ANTHROPIC_TWIN="http://localhost:18080"
OPENAI_TWIN="http://localhost:18081"

SID=""
TMPDIR_CREATED=""

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
    tui-wright screen "$sid" 2>/dev/null | tail -20
    fail "$label (expected '$expected')"
  fi
}

cleanup() {
  if [[ -n "$SID" ]]; then
    tui-wright kill "$SID" 2>/dev/null || true
  fi
  if [[ -n "$TMPDIR_CREATED" ]]; then
    rm -rf "$TMPDIR_CREATED"
  fi
}
trap cleanup EXIT

ensure_twins_up() {
  local healthy=true
  if ! curl -sf "$ANTHROPIC_TWIN/__control/health" > /dev/null 2>&1; then
    healthy=false
  fi
  if ! curl -sf "$OPENAI_TWIN/__control/health" > /dev/null 2>&1; then
    healthy=false
  fi
  if $healthy; then
    echo "Both twins already healthy."
    return
  fi
  echo "Starting twin containers..."
  docker compose -f "$PROJECT/twins/docker-compose.yml" up -d --wait
  for i in $(seq 1 15); do
    if curl -sf "$ANTHROPIC_TWIN/__control/health" > /dev/null 2>&1 && \
       curl -sf "$OPENAI_TWIN/__control/health" > /dev/null 2>&1; then
      echo "Both twins are healthy."
      return
    fi
    sleep 1
  done
  echo "FATAL: twins did not become healthy"
  exit 1
}

# ── Build ─────────────────────────────────────────────────────

echo "── twin-crossreview: /crossreview E2E test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  (cd "$PROJECT" && cargo build 2>&1)
fi

ensure_twins_up

# ── Create init file to configure OpenAI twin ────────────────

TMPDIR_CREATED=$(mktemp -d)
INIT_FILE="$TMPDIR_CREATED/openai-twin-init.janet"
cat > "$INIT_FILE" <<'JANET'
(import core/api :as api)
(import core/auth :as auth)
(api/set-provider-url "openai" "http://localhost:18081/v1/responses")
(auth/set-runtime-key "openai" "test-key")
JANET
echo "Init file: $INIT_FILE"

# ── Reset both twins ─────────────────────────────────────────

echo "Resetting twin control planes..."
curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null
curl -sf -X POST "$OPENAI_TWIN/__control/reset" > /dev/null

# ── Enqueue responses ────────────────────────────────────────

echo "Enqueuing Anthropic response..."
curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"We should use a microservices architecture."}' > /dev/null

echo "Enqueuing OpenAI review response..."
curl -sf -X POST "$OPENAI_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"The microservices suggestion lacks nuance. Consider a modular monolith first."}' > /dev/null

# ── Spawn gent session ──────────────────────────────────────

echo "Spawning gent (${COLS}x${ROWS}) with Anthropic twin + OpenAI twin config..."
SID_LINE=$(GENT_API_URL="$ANTHROPIC_TWIN/v1/messages" GENT_API_KEY="test-key" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS" -- -l "$INIT_FILE")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

# ── Test 1: Submit a message and get Anthropic response ──────

echo "Typing user message..."
tui-wright type "$SID" "What architecture should we use?"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "microservices architecture" "anthropic response appears" 15000

# ── Test 2: Run /crossreview and verify OpenAI review appears ─

echo "Running /crossreview..."
tui-wright type "$SID" "/crossreview"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "OpenAI (Codex):" "openai cross-review appears in TUI" 30000

# ── Test 3: Verify the OpenAI twin received the review request ─

echo "Checking OpenAI twin request log..."
REQUESTS=$(curl -sf "$OPENAI_TWIN/__control/requests")

if echo "$REQUESTS" | jq -e '.[0]' > /dev/null 2>&1; then
  pass "openai twin received a request"
else
  fail "openai twin received no requests"
  echo "  Requests: $REQUESTS"
fi

# Check that the review request references the original response
if echo "$REQUESTS" | jq -r '.[0].input // empty' 2>/dev/null | grep -q "microservices"; then
  pass "openai review request contains original response"
elif echo "$REQUESTS" | jq -r '.[0].body.input // empty' 2>/dev/null | grep -q "microservices"; then
  pass "openai review request contains original response"
else
  fail "openai review request does not reference the original response"
  echo "  First request keys: $(echo "$REQUESTS" | jq '.[0] | keys' 2>/dev/null)"
fi

# ── Test 4: Verify the review label shows provider name ──

assert_screen_contains "$SID" "OpenAI (Codex):" "review label shows provider name" 5000

# ── Results ───────────────────────────────────────────────────

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
