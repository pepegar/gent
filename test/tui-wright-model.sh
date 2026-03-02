#!/usr/bin/env bash
# test/tui-wright-model.sh — Integration test for /model command using tui-wright.
#
# Spawns gent in stage mode in a headless pty via tui-wright, then exercises
# the /model command to switch models and verify the change via /config.
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
  if tui-wright wait-for "$sid" "$expected" --timeout 5000 > /dev/null 2>&1; then
    pass "$label"
  else
    echo "  Screen contents:"
    tui-wright screen "$sid" 2>/dev/null | tail -10
    fail "$label (expected '$expected')"
  fi
}

# ── Build ─────────────────────────────────────────────────────

echo "── tui-wright /model integration test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  cargo build 2>&1
fi

# ── Spawn session ─────────────────────────────────────────────

echo "Spawning gent session in stage mode (${COLS}x${ROWS})..."
SID_LINE=$(GENT_STAGE=1 tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

sleep 1

if ! tui-wright wait-for "$SID" "focus:" --timeout 10000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  tui-wright kill "$SID" 2>/dev/null
  exit 1
fi

# ── Test 1: /model with no args lists models ─────────────────

tui-wright type "$SID" "/model"
tui-wright key "$SID" enter
sleep 3
assert_screen_contains "$SID" "Current:" "/model lists models and shows current"

# ── Test 2: /model <name> switches model ──────────────────────

tui-wright type "$SID" "/model test-model-switch-123"
tui-wright key "$SID" enter
sleep 1
assert_screen_contains "$SID" "Switched to model: test-model-switch-123" "/model <name> shows switched message"

# ── Test 3: /config reflects the model change ────────────────

tui-wright type "$SID" "/config"
tui-wright key "$SID" enter
sleep 1
assert_screen_contains "$SID" "test-model-switch-123" "/config shows the new model name"

# ── Cleanup ───────────────────────────────────────────────────

tui-wright kill "$SID" 2>/dev/null || true

echo ""
echo "═══ Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ═══"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
