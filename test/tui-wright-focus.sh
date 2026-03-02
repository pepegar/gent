#!/usr/bin/env bash
# test/tui-wright-focus.sh — Integration test for focus navigation using tui-wright.
#
# Spawns gent in a headless pty via tui-wright, then exercises Alt+Arrow focus
# navigation and asserts the editor border title shows the correct focus target.
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#
# Usage: bash test/tui-wright-focus.sh

set -euo pipefail

GENT="./target/debug/gent"
COLS=80
ROWS=24
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

assert_focus() {
  local sid="$1"
  local expected="$2"
  local label="$3"
  if tui-wright wait-for "$sid" "focus: $expected" --timeout 3000 > /dev/null 2>&1; then
    pass "$label"
  else
    echo "  Screen contents:"
    tui-wright screen "$sid" 2>/dev/null | tail -5
    fail "$label (expected 'focus: $expected')"
  fi
}

# ── Build ─────────────────────────────────────────────────────

echo "── tui-wright focus integration test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  cargo build 2>&1
fi

# ── Spawn session ─────────────────────────────────────────────

echo "Spawning gent session (${COLS}x${ROWS})..."
SID_LINE=$(tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

sleep 1

if ! tui-wright wait-for "$SID" "focus:" --timeout 10000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  tui-wright kill "$SID" 2>/dev/null
  exit 1
fi

# ── Test 1: Initial focus is on editor ────────────────────────

assert_focus "$SID" "editor" "initial focus is editor"

# ── Test 2: Alt+Up → chat ────────────────────────────────────

tui-wright key "$SID" "alt+up"
sleep 0.3
assert_focus "$SID" "chat" "Alt+Up moves focus to chat"

# ── Test 3: Alt+Down → editor ────────────────────────────────

tui-wright key "$SID" "alt+down"
sleep 0.3
assert_focus "$SID" "editor" "Alt+Down moves focus back to editor"

# ── Test 4: Round-trip ────────────────────────────────────────

tui-wright key "$SID" "alt+up"
sleep 0.3
tui-wright key "$SID" "alt+down"
sleep 0.3
assert_focus "$SID" "editor" "round-trip: editor → chat → editor"

# ── Cleanup ───────────────────────────────────────────────────

tui-wright kill "$SID" 2>/dev/null || true

echo ""
echo "═══ Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ═══"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
