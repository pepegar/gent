#!/usr/bin/env bash
# test/tui-wright-model.sh — Integration test for /model and /provider selectors.
#
# Spawns gent in a staged session via tui-wright, then exercises the interactive
# selector overlays for /model and /provider and verifies the selected values
# via /config.
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#
# Usage: bash test/tui-wright-model.sh

set -euo pipefail

GENT="./target/debug/gent"
COLS=100
ROWS=30
PASS=0
FAIL=0
STAGE_SCRIPT=""

# ── Helpers ───────────────────────────────────────────────────

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}

assert_screen_contains() {
  local sid="$1"
  local expected="$2"
  local label="$3"
  local timeout="${4:-5000}"
  if tui-wright wait-for "$sid" "$expected" --timeout "$timeout" > /dev/null 2>&1; then
    pass "$label"
  else
    echo "  Screen contents:"
    tui-wright screen "$sid" 2>/dev/null | tail -20
    fail "$label (expected '$expected')"
  fi
}

cleanup() {
  [ -n "${SID:-}" ] && tui-wright kill "$SID" 2>/dev/null || true
  [ -n "$STAGE_SCRIPT" ] && rm -f "$STAGE_SCRIPT"
}
trap cleanup EXIT

# ── Build ─────────────────────────────────────────────────────

echo "── tui-wright /model + /provider selector integration test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  cargo build 2>&1
fi

# ── Stage setup ───────────────────────────────────────────────

STAGE_SCRIPT=$(mktemp /tmp/gent-stage-model-provider-XXXXX.janet)
cat > "$STAGE_SCRIPT" << 'EOF'
(import core/api :as api)

# Use OpenAI so /model can list the provider's static known models.
(api/set-provider "openai")
EOF

# ── Spawn session ─────────────────────────────────────────────

echo "Spawning gent session in stage mode (${COLS}x${ROWS})..."
SID_LINE=$(GENT_PROVIDER=openai GENT_API_KEY=stage-test-key GENT_STAGE="$STAGE_SCRIPT" tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

sleep 1

if ! tui-wright wait-for "$SID" "focus:" --timeout 10000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

# ── Test 1: /model opens selector ─────────────────────────────

tui-wright type "$SID" "/model"
tui-wright key "$SID" enter
assert_screen_contains "$SID" "Models" "/model opens selector overlay"
assert_screen_contains "$SID" "gpt-5.1" "/model selector shows model choices"

# ── Test 2: /model selector search + enter switches model ────

tui-wright type "$SID" "5.4"
tui-wright key "$SID" enter

tui-wright type "$SID" "/config"
tui-wright key "$SID" enter
pass "/model selector applies selected model"
assert_screen_contains "$SID" "provider: openai" "/config shows openai provider after /model selector"
assert_screen_contains "$SID" "model: gpt-5.4" "/config shows model selected from /model selector"

# ── Test 3: /provider opens selector ──────────────────────────

tui-wright type "$SID" "/provider"
tui-wright key "$SID" enter
assert_screen_contains "$SID" "Providers" "/provider opens selector overlay"
assert_screen_contains "$SID" "anthropic" "/provider selector shows anthropic"
assert_screen_contains "$SID" "openai" "/provider selector shows openai"

# ── Test 4: /provider selector enter switches provider ────────

tui-wright key "$SID" enter

tui-wright type "$SID" "/config"
tui-wright key "$SID" enter
pass "/provider selector applies selected provider"
assert_screen_contains "$SID" "provider: anthropic" "/config shows provider selected from /provider selector"
assert_screen_contains "$SID" "model: claude-sonnet-4-20250514" "/config shows provider default model after switch"

echo ""
echo "═══ Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ═══"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
