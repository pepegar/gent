#!/usr/bin/env bash
# test/twin-error-scenarios.sh — Comprehensive error scenario E2E tests via digital twin servers.
#
# Tests non-happy-path error scenarios including various HTTP error codes,
# recovery sequences, multiple consecutive errors, tool call responses,
# thinking + text responses, and OpenAI twin error handling.
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#   - docker compose (twins at twins/docker-compose.yml)
#   - curl and jq on PATH
#
# Usage: bash test/twin-error-scenarios.sh

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
  if [[ -n "${FAKE_HOME:-}" ]]; then
    rm -rf "$FAKE_HOME"
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

FAKE_HOME=$(mktemp -d)

spawn_gent_anthropic() {
  local sid_line
  sid_line=$(HOME="$FAKE_HOME" GENT_API_URL="$TWIN_API_URL" GENT_API_KEY="$TWIN_API_KEY" \
    tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS" -- -q)
  SID=$(echo "$sid_line" | sed 's/session: //')
  echo "Session: $SID"

  if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
    echo "FATAL: gent did not start within timeout"
    tui-wright screen "$SID" 2>/dev/null
    exit 1
  fi
}

spawn_gent_openai() {
  local sid_line
  sid_line=$(HOME="$FAKE_HOME" GENT_API_URL="$OPENAI_TWIN/v1/responses" GENT_API_KEY="$TWIN_API_KEY" \
    tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS" -- -q)
  SID=$(echo "$sid_line" | sed 's/session: //')
  echo "Session: $SID"

  if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
    echo "FATAL: gent did not start within timeout"
    tui-wright screen "$SID" 2>/dev/null
    exit 1
  fi
}

kill_gent() {
  if [[ -n "$SID" ]]; then
    tui-wright kill "$SID" 2>/dev/null || true
    SID=""
  fi
}

# ── Build ─────────────────────────────────────────────────────

echo "── twin-error-scenarios: comprehensive error scenario E2E tests ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  (cd "$PROJECT" && cargo build 2>&1)
fi

ensure_twins_up

# ══════════════════════════════════════════════════════════════
# Test 1: HTTP 403 Forbidden
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 1: HTTP 403 Forbidden ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":403,"message":"Access denied","error_type":"permission_error"}' > /dev/null

spawn_gent_anthropic

tui-wright type "$SID" "Trigger 403 error"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "err:" "403 forbidden: error indicator appears in TUI" 15000

kill_gent

# ══════════════════════════════════════════════════════════════
# Test 2: HTTP 500 Internal Server Error
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 2: HTTP 500 Internal Server Error ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":500,"message":"Internal server error","error_type":"api_error"}' > /dev/null

spawn_gent_anthropic

tui-wright type "$SID" "Trigger 500 error"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "err:" "500 internal server error: error indicator appears in TUI" 15000

kill_gent

# ══════════════════════════════════════════════════════════════
# Test 3: HTTP 529 Overloaded
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 3: HTTP 529 Overloaded ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":529,"message":"API is overloaded","error_type":"overloaded_error"}' > /dev/null

spawn_gent_anthropic

tui-wright type "$SID" "Trigger 529 overloaded"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "err:" "529 overloaded: error indicator appears in TUI" 15000

kill_gent

# ══════════════════════════════════════════════════════════════
# Test 4: Recovery sequence — error then success
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 4: Recovery sequence — error then success ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":500,"message":"temporary failure","error_type":"api_error"}' > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"Back online!"}' > /dev/null

spawn_gent_anthropic

tui-wright type "$SID" "First message triggers error"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "err:" "recovery: first message shows error" 15000

tui-wright type "$SID" "Second message should succeed"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "Back online!" "recovery: second message shows success after error" 15000

kill_gent

# ══════════════════════════════════════════════════════════════
# Test 5: Multiple consecutive errors then success
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 5: Multiple consecutive errors then success ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":500,"message":"server error 1","error_type":"api_error"}' > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":429,"message":"rate limited","error_type":"rate_limit_error"}' > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":500,"message":"server error 2","error_type":"api_error"}' > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"Finally recovered!"}' > /dev/null

spawn_gent_anthropic

tui-wright type "$SID" "Message one"
tui-wright key "$SID" enter
assert_screen_contains "$SID" "err:" "consecutive errors: first message shows error" 15000

tui-wright type "$SID" "Message two"
tui-wright key "$SID" enter
# Wait for second error — screen already has "err:" from first, so we need a
# strategy. We wait for the input to be processed and then check that the user
# can still type (gent returned to idle). We look for the echo of the second
# message being sent, then check error appears again.
sleep 3
# The screen should still contain err: (there are now two errors on screen)
assert_screen_contains "$SID" "err:" "consecutive errors: second message shows error" 15000

tui-wright type "$SID" "Message three"
tui-wright key "$SID" enter
sleep 3
assert_screen_contains "$SID" "err:" "consecutive errors: third message shows error" 15000

tui-wright type "$SID" "Message four"
tui-wright key "$SID" enter
assert_screen_contains "$SID" "Finally recovered!" "consecutive errors: fourth message shows success" 15000

kill_gent

# ══════════════════════════════════════════════════════════════
# Test 6: Tool call response
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 6: Tool call response ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"tool_call","tool_id":"toolu_test1","name":"bash","input":{"command":"echo hello"}}' > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"The command output hello."}' > /dev/null

spawn_gent_anthropic

tui-wright type "$SID" "Run echo hello"
tui-wright key "$SID" enter

# The tool call should trigger bash execution; look for the tool name or the
# dollar sign prompt that gent uses for bash, then the follow-up text response.
assert_screen_contains "$SID" "The command output hello." "tool call: text follow-up appears after tool execution" 15000

kill_gent

# ══════════════════════════════════════════════════════════════
# Test 7: Thinking + text response
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 7: Thinking + text response ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"thinking_then_text","thinking":"Let me think about this...","text":"Here is my answer."}' > /dev/null

spawn_gent_anthropic

tui-wright type "$SID" "Think about something"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "Here is my answer." "thinking + text: text content appears in TUI" 15000

kill_gent

# ══════════════════════════════════════════════════════════════
# Test 8: OpenAI twin basic error and recovery
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Test 8: OpenAI twin error and recovery ──"

curl -sf -X POST "$OPENAI_TWIN/__control/reset" > /dev/null

curl -sf -X POST "$OPENAI_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"error","status":500,"message":"OpenAI internal error","error_type":"server_error"}' > /dev/null

curl -sf -X POST "$OPENAI_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"OpenAI recovered successfully!"}' > /dev/null

spawn_gent_openai

# Switch to OpenAI provider via /model (gpt- prefix auto-selects openai)
tui-wright type "$SID" "/model gpt-5.1"
tui-wright key "$SID" enter
assert_screen_contains "$SID" "Switched to model:" "openai: /model command accepted" 5000

tui-wright type "$SID" "Trigger OpenAI error"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "err:" "openai error: error indicator appears in TUI" 15000

tui-wright type "$SID" "OpenAI should recover"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "OpenAI recovered successfully!" "openai recovery: success response after error" 15000

kill_gent

# ── Results ───────────────────────────────────────────────────

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
