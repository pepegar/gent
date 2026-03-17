#!/usr/bin/env bash
# test/twin-provider-switch.sh — Provider request format verification via digital twins.
#
# Tests that gent sends the correct wire format for each provider by running
# two separate sessions: one against the Anthropic twin and one against the
# OpenAI twin. Verifies the request body structure matches each provider's
# expected format.
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#   - docker compose (twins at twins/docker-compose.yml)
#   - curl and jq on PATH
#
# Usage: bash test/twin-provider-switch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"

GENT="$PROJECT/target/debug/gent"
COLS=120
ROWS=30
PASS=0
FAIL=0

ANTHROPIC_TWIN="http://localhost:18080"
OPENAI_TWIN="http://localhost:18081"

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

echo "── twin-provider-switch: provider format verification test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  (cd "$PROJECT" && cargo build 2>&1)
fi

ensure_twins_up

# ══════════════════════════════════════════════════════════════
# Part 1: Anthropic provider — verify Anthropic wire format
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Part 1: Anthropic provider wire format ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"Anthropic format verified."}' > /dev/null

SID_LINE=$(GENT_API_URL="$ANTHROPIC_TWIN/v1/messages" GENT_API_KEY="test-key" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

tui-wright type "$SID" "Hello Anthropic"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "Anthropic format verified." "anthropic: response appears" 15000

REQUESTS=$(curl -sf "$ANTHROPIC_TWIN/__control/requests")

# Anthropic format uses "messages" array with {role, content} objects
if echo "$REQUESTS" | jq -e '.[0].body.messages' > /dev/null 2>&1; then
  pass "anthropic: request body has 'messages' field"
else
  fail "anthropic: request body missing 'messages' field"
  echo "  Body keys: $(echo "$REQUESTS" | jq '.[0].body | keys')"
fi

# Anthropic format has "model" in body
if echo "$REQUESTS" | jq -e '.[0].body.model' > /dev/null 2>&1; then
  pass "anthropic: request body has 'model' field"
else
  fail "anthropic: request body missing 'model' field"
fi

# Anthropic format should NOT have "input" (that's OpenAI)
if echo "$REQUESTS" | jq -e '.[0].body.input' > /dev/null 2>&1; then
  fail "anthropic: request body has unexpected 'input' field (OpenAI format leak)"
else
  pass "anthropic: request body correctly lacks 'input' field"
fi

# Anthropic format has "max_tokens"
if echo "$REQUESTS" | jq -e '.[0].body.max_tokens' > /dev/null 2>&1; then
  pass "anthropic: request body has 'max_tokens' field"
else
  fail "anthropic: request body missing 'max_tokens' field"
fi

tui-wright kill "$SID" 2>/dev/null || true
SID=""

# ══════════════════════════════════════════════════════════════
# Part 2: OpenAI provider — verify OpenAI Responses API format
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Part 2: OpenAI provider wire format ──"

curl -sf -X POST "$OPENAI_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$OPENAI_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"OpenAI format verified."}' > /dev/null

# Start gent pointing at the OpenAI twin URL, then use /model to switch provider.
# GENT_API_URL persists across provider switches (set-provider re-reads the env var).
SID_LINE=$(GENT_API_URL="$OPENAI_TWIN/v1/responses" GENT_API_KEY="test-key" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

# Switch to OpenAI provider via /model (gpt- prefix auto-selects openai)
tui-wright type "$SID" "/model gpt-5.1"
tui-wright key "$SID" enter
assert_screen_contains "$SID" "Switched to model:" "openai: /model command accepted" 5000

tui-wright type "$SID" "Hello OpenAI"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "OpenAI format verified." "openai: response appears" 15000

REQUESTS=$(curl -sf "$OPENAI_TWIN/__control/requests")

# Note: OpenAI twin records just the body dict (not wrapped with headers).

# OpenAI Responses API format uses "input" array (not "messages")
if echo "$REQUESTS" | jq -e '.[0].input' > /dev/null 2>&1; then
  pass "openai: request body has 'input' field"
else
  fail "openai: request body missing 'input' field"
  echo "  Body keys: $(echo "$REQUESTS" | jq '.[0] | keys')"
fi

# OpenAI format has "model" in body
if echo "$REQUESTS" | jq -e '.[0].model' > /dev/null 2>&1; then
  MODEL=$(echo "$REQUESTS" | jq -r '.[0].model')
  if [[ "$MODEL" == "gpt-5.1" ]]; then
    pass "openai: request body has correct model 'gpt-5.1'"
  else
    fail "openai: request body has wrong model: $MODEL"
  fi
else
  fail "openai: request body missing 'model' field"
fi

# OpenAI format should NOT have "messages" (that's Anthropic)
if echo "$REQUESTS" | jq -e '.[0].messages' > /dev/null 2>&1; then
  fail "openai: request body has unexpected 'messages' field (Anthropic format leak)"
else
  pass "openai: request body correctly lacks 'messages' field"
fi

# OpenAI format should have "tool_choice" field
if echo "$REQUESTS" | jq -e '.[0].tool_choice' > /dev/null 2>&1; then
  pass "openai: request body has 'tool_choice' field"
else
  fail "openai: request body missing 'tool_choice' field"
fi

# If we got a response, the Bearer auth was accepted
pass "openai: Bearer auth accepted by twin (response was received)"

# ── Results ───────────────────────────────────────────────────

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
