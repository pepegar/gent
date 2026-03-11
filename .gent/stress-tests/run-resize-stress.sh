#!/usr/bin/env bash
set -euo pipefail

# Resize stress test: rapidly change terminal dimensions during streaming

PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
STRESS_DIR="$PROJECT/.gent/stress-tests"
RESULTS_DIR="$PROJECT/.gent/stress-results"
GENT_BIN="$PROJECT/target/debug/gent"

mkdir -p "$RESULTS_DIR"

echo "=== Resize stress test ==="

SESSION=$(tui-wright spawn bash --cols 100 --rows 30 2>&1 | grep -oE '[a-f0-9]+$')
echo "Session: $SESSION"

# Launch gent with profiling and streaming stage
tui-wright type "$SESSION" " cd $PROJECT && GENT_PROFILE=1 GENT_STAGE=$STRESS_DIR/stage-heavy-markdown-stream.janet $GENT_BIN"
tui-wright key "$SESSION" enter
sleep 3

# Reset profiling
tui-wright type "$SESSION" "/profile reset"
tui-wright key "$SESSION" enter
sleep 0.5

# Submit to trigger streaming
tui-wright type "$SESSION" "resize stress test"
tui-wright key "$SESSION" enter

# While streaming, resize rapidly
sleep 1
for i in $(seq 1 20); do
  # Cycle through different sizes
  tui-wright resize "$SESSION" 80 24
  sleep 0.2
  tui-wright resize "$SESSION" 120 40
  sleep 0.2
  tui-wright resize "$SESSION" 60 20
  sleep 0.2
  tui-wright resize "$SESSION" 200 50
  sleep 0.2
done

sleep 3

# Collect stats
echo "=== PROFILING STATS ===" > "$RESULTS_DIR/resize-stress.txt"
tui-wright type "$SESSION" "/profile stats"
tui-wright key "$SESSION" enter
sleep 1
for i in $(seq 1 200); do tui-wright mouse "$SESSION" scrolldown 50 15; done
sleep 1
tui-wright screen "$SESSION" >> "$RESULTS_DIR/resize-stress.txt" 2>&1

tui-wright type "$SESSION" "/profile dump"
tui-wright key "$SESSION" enter
sleep 0.5

# Capture final screen
echo "" >> "$RESULTS_DIR/resize-stress.txt"
echo "=== FINAL SCREEN ===" >> "$RESULTS_DIR/resize-stress.txt"
tui-wright screen "$SESSION" >> "$RESULTS_DIR/resize-stress.txt" 2>&1

tui-wright key "$SESSION" ctrl+c
sleep 1
tui-wright kill "$SESSION" 2>/dev/null || true

# Copy profile
latest=$(ls -t "$PROJECT"/.gent/profile-*.json 2>/dev/null | head -1 || true)
if [[ -n "$latest" ]]; then
  cp "$latest" "$RESULTS_DIR/resize-stress-trace.json"
fi

echo "Results in: $RESULTS_DIR/resize-stress.txt"
