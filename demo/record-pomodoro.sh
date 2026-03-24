#!/usr/bin/env bash
# demo/record-pomodoro.sh — Record the pomodoro widget demo.
#
# Shows: asking gent to add a live pomodoro timer widget to the TUI at runtime.
# Produces an asciicast v2 file at demo/pomodoro.cast
# Requires: tui-wright, a built release binary

set -euo pipefail

GENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GENT_BIN="${GENT_DIR}/target/release/gent"
STAGE_SCRIPT="${GENT_DIR}/demo/stage-pomodoro.janet"
CAST="${GENT_DIR}/demo/pomodoro.cast"
COLS=120
ROWS=34

if [ ! -f "$GENT_BIN" ]; then
  echo "Build gent first: cargo build --release"
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────

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

tui-wright type "$SESSION" "/clear"
tui-wright key "$SESSION" enter
sleep 0.5

echo "Gent booted and cleared."

# ── Start recording ──────────────────────────────────────────

tui-wright trace start "$SESSION" --output "$CAST"

# Force a full redraw
tui-wright resize "$SESSION" 119 33
sleep 0.3
tui-wright resize "$SESSION" "$COLS" "$ROWS"
sleep 0.5

# Let the viewer see the clean TUI for a beat
sleep 1.0

# ── Act 1: Ask for the pomodoro widget ───────────────────────

fast_type "$SESSION" "Add a pomodoro timer widget to the UI"
sleep 0.5
tui-wright key "$SESSION" enter

# Wait for streaming confirmation (~2s thinking/tool + streaming text)
tui-wright wait-for "$SESSION" "No restart needed" --timeout 20000
sleep 2.0

# ── Act 2: Watch the timer tick ──────────────────────────────

sleep 3.0

# ── Act 3: Type the CTA ─────────────────────────────────────

fast_type "$SESSION" "https://try.gent"
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
