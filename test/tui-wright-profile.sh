#!/usr/bin/env bash
# test/tui-wright-profile.sh — Performance regression test using tui-wright.
#
# Spawns gent in stage mode with profiling enabled, streams a long response to
# build up scrollback, then runs a scroll benchmark and asserts that
# render:frame avg stays under 16ms (60 fps budget).
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#
# Usage: bash test/tui-wright-profile.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"

GENT="$PROJECT/target/debug/gent"
COLS=100
ROWS=30

# render:frame avg must stay under this threshold (ms) to pass.
# Override via env: FRAME_TIME_LIMIT=100 bash test/tui-wright-profile.sh
# CI sets this to 100ms (generous on shared runners); dev default is 16ms.
FRAME_TIME_LIMIT="${FRAME_TIME_LIMIT:-16}"

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
  local timeout="${4:-5000}"
  if tui-wright wait-for "$sid" "$expected" --timeout "$timeout" > /dev/null 2>&1; then
    pass "$label"
  else
    echo "  Screen contents:"
    tui-wright screen "$sid" 2>/dev/null | tail -10
    fail "$label (expected '$expected')"
  fi
}

# ── Stage script: 200 long lines for scroll depth ─────────────

STAGE_SCRIPT="$(mktemp /tmp/profile-stage.XXXXXX.janet)"
cat > "$STAGE_SCRIPT" << 'JANET'
(import core/stage :as stage)
(stage/respond (stage/text-stream
  (string/join
    (seq [i :range [0 200]]
      (string "Line " i ": Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
              "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."))
    "\n")
  :token-delay 0.001))
JANET

SID=""

cleanup() {
  rm -f "$STAGE_SCRIPT"
  if [[ -n "$SID" ]]; then
    tui-wright kill "$SID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Build ─────────────────────────────────────────────────────

echo "── tui-wright performance regression test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  cd "$PROJECT" && cargo build 2>&1
fi

# ── Spawn session ─────────────────────────────────────────────

echo "Spawning gent (${COLS}x${ROWS}, profiling + stage mode)..."
SID_LINE=$(GENT_PROFILE=1 GENT_STAGE="$STAGE_SCRIPT" tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS")
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 10000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

# ── Trigger staged response (200 long lines) ──────────────────

echo "Submitting prompt to trigger long staged response..."
tui-wright type "$SID" "scroll benchmark"
tui-wright key "$SID" enter
# Wait for the stream to finish (200 lines × 0.001s ≈ 0.2s + overhead)
sleep 4

# ── Reset profiling to isolate scroll events ──────────────────

echo "Resetting profiling counters..."
tui-wright type "$SID" "/profile reset"
tui-wright key "$SID" enter
sleep 0.5

# ── Scroll benchmark: 50 up + 50 down ────────────────────────

echo "Running scroll benchmark (50 up + 50 down)..."
for i in $(seq 1 50); do tui-wright mouse "$SID" scrollup 50 15; done
sleep 1
for i in $(seq 1 50); do tui-wright mouse "$SID" scrolldown 50 15; done
sleep 1

# ── Collect profiling stats ───────────────────────────────────

echo "Collecting /profile stats..."
tui-wright type "$SID" "/profile stats"
tui-wright key "$SID" enter
sleep 0.5

# Scroll to the bottom so stats are visible
for i in $(seq 1 200); do tui-wright mouse "$SID" scrolldown 50 15; done
sleep 0.5

assert_screen_contains "$SID" "render:frame" "profiling stats appear on screen" 5000

SCREEN=$(tui-wright screen "$SID")

# ── Parse render:frame avg ────────────────────────────────────

FRAME_LINE=$(echo "$SCREEN" | grep "render:frame" || true)

if [[ -z "$FRAME_LINE" ]]; then
  fail "render:frame stat not found in screen output"
  echo "Screen:"
  echo "$SCREEN"
else
  # Stats format: Name  Count  Total(ms)  Avg(ms)  Min(ms)  Max(ms)
  # render:frame is the 4th whitespace-delimited field after the name
  FRAME_AVG=$(echo "$FRAME_LINE" | awk '{print $4}')
  echo "  render:frame avg: ${FRAME_AVG}ms (limit: ${FRAME_TIME_LIMIT}ms)"
  if awk "BEGIN { exit ($FRAME_AVG < $FRAME_TIME_LIMIT) ? 0 : 1 }"; then
    pass "render:frame avg ${FRAME_AVG}ms is under ${FRAME_TIME_LIMIT}ms"
  else
    fail "render:frame avg ${FRAME_AVG}ms >= ${FRAME_TIME_LIMIT}ms (performance regression)"
    echo "  Full stats:"
    echo "$SCREEN" | grep -A 20 "Profiling:" || echo "$SCREEN"
  fi
fi

# ── Results ──────────────────────────────────────────────────

echo ""
echo "═══ Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ═══"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
