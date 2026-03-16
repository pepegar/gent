#!/usr/bin/env bash
# demo/record-homepage.sh — Record the gent homepage asciicast via tui-wright.
#
# Produces an asciicast v2 file at demo/homepage.cast
# Requires: tui-wright, rg (ripgrep), a built release binary

set -euo pipefail

GENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GENT_BIN="${GENT_DIR}/target/release/gent"
STAGE_SCRIPT="${GENT_DIR}/demo/stage-homepage.janet"
CAST="${GENT_DIR}/demo/homepage.cast"
COLS=100
ROWS=30

if [ ! -f "$GENT_BIN" ]; then
  echo "Build gent first: cargo build --release"
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────

# Type like a very fast human (~20ms per character)
fast_type() {
  local session="$1"
  local text="$2"
  for (( i=0; i<${#text}; i++ )); do
    tui-wright type "$session" "${text:$i:1}"
    sleep 0.020
  done
}

cleanup() {
  [ -n "${SESSION:-}" ] && tui-wright kill "$SESSION" 2>/dev/null || true
}
trap cleanup EXIT

# ── Boot gent (not recorded) ─────────────────────────────────

SESSION=$(tui-wright spawn bash --cols "$COLS" --rows "$ROWS" 2>&1 | awk '{print $NF}')
echo "Session: $SESSION"

tui-wright type "$SESSION" " cd $GENT_DIR && GENT_STAGE=$STAGE_SCRIPT $GENT_BIN -q"
tui-wright key "$SESSION" enter
sleep 3

# Clear the banner (skills list, paths, etc.) so the recording starts clean
tui-wright type "$SESSION" "/clear"
tui-wright key "$SESSION" enter
sleep 0.5

echo "Gent booted and cleared."

# ── Start recording ──────────────────────────────────────────

tui-wright trace start "$SESSION" --output "$CAST"

# Force a full redraw: resize to a different size and back
tui-wright resize "$SESSION" 99 29
sleep 0.3
tui-wright resize "$SESSION" "$COLS" "$ROWS"
sleep 0.5

# Let the viewer see the clean TUI for a beat
sleep 1.0

# ── Act 1: Create a tool (~1-15s) ───────────────────────────

fast_type "$SESSION" "Create a tool that searches with ripgrep"
sleep 0.5
tui-wright key "$SESSION" enter

# Wait for streaming confirmation to finish
tui-wright wait-for "$SESSION" "No restart needed" --timeout 10000
sleep 2.0

# ── Act 2: Use it immediately (~15-30s) ─────────────────────

fast_type "$SESSION" "Use rg to find hook definitions in janet/core/hooks.janet"
sleep 0.5
tui-wright key "$SESSION" enter

# Wait for the final streaming summary to finish (last line of response 4)
tui-wright wait-for "$SESSION" "intercept tool calls" --timeout 15000

# Let the viewer read the final result
sleep 2.0

# ── End ──────────────────────────────────────────────────────

tui-wright trace stop "$SESSION"
tui-wright key "$SESSION" ctrl+c
sleep 0.5
tui-wright kill "$SESSION" 2>/dev/null || true
trap - EXIT

echo ""
echo "Recorded: $CAST"
echo "Play:     asciinema play $CAST"
