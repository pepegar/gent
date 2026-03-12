#!/usr/bin/env bash
set -euo pipefail

# Stress test benchmark runner for gent rendering
# Uses tui-wright + stage mode + profiling
#
# Usage: bash .gent/stress-tests/run-benchmark.sh [test-name] [cols] [rows]
#   test-name: massive-scrollback | heavy-markdown-stream | thinking-blocks | rapid-updates | all
#   cols: terminal width (default 100)
#   rows: terminal height (default 30)

PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
STRESS_DIR="$PROJECT/.gent/stress-tests"
RESULTS_DIR="$PROJECT/.gent/stress-results"
GENT_BIN="$PROJECT/target/debug/gent"

TEST_NAME="${1:-all}"
COLS="${2:-100}"
ROWS="${3:-30}"

mkdir -p "$RESULTS_DIR"

run_benchmark() {
  local name="$1"
  local stage_script="$STRESS_DIR/stage-${name}.janet"
  local result_file="$RESULTS_DIR/${name}-${COLS}x${ROWS}.txt"
  local profile_prefix="stress-${name}-${COLS}x${ROWS}"

  echo "=== Running benchmark: $name (${COLS}x${ROWS}) ==="

  if [[ ! -f "$stage_script" ]]; then
    echo "ERROR: Stage script not found: $stage_script"
    return 1
  fi

  # Spawn session
  local session
  session=$(tui-wright spawn bash --cols "$COLS" --rows "$ROWS" 2>&1 | grep -oE '[a-f0-9]+$')
  echo "Session: $session"

  # Launch gent with profiling and stage mode
  tui-wright type "$session" " cd $PROJECT && GENT_PROFILE=1 GENT_STAGE=$stage_script $GENT_BIN"
  tui-wright key "$session" enter
  sleep 3

  # Capture initial screen
  echo "--- Initial screen ---" > "$result_file"
  tui-wright screen "$session" >> "$result_file" 2>&1

  # Submit prompt to trigger staged response
  tui-wright type "$session" "stress test: $name"
  tui-wright key "$session" enter

  # Wait for response based on test type
  case "$name" in
    massive-scrollback)
      sleep 3
      # Reset profiling, then do scroll stress
      tui-wright type "$session" "/profile reset"
      tui-wright key "$session" enter
      sleep 1

      echo "--- Scroll up stress (100 events) ---" >> "$result_file"
      for i in $(seq 1 100); do
        tui-wright mouse "$session" scrollup 50 15
      done
      sleep 2

      echo "--- Scroll down stress (100 events) ---" >> "$result_file"
      for i in $(seq 1 100); do
        tui-wright mouse "$session" scrolldown 50 15
      done
      sleep 2

      # Another burst: rapid alternating scroll
      echo "--- Alternating scroll stress (50 pairs) ---" >> "$result_file"
      tui-wright type "$session" "/profile reset"
      tui-wright key "$session" enter
      sleep 0.5
      for i in $(seq 1 50); do
        tui-wright mouse "$session" scrollup 50 15
        tui-wright mouse "$session" scrolldown 50 15
      done
      sleep 2
      ;;

    heavy-markdown-stream)
      sleep 8
      ;;

    thinking-blocks)
      sleep 6
      # After first response, submit again for second thinking block
      tui-wright type "$session" "continue analysis"
      tui-wright key "$session" enter
      sleep 6
      # Third response
      tui-wright type "$session" "final check"
      tui-wright key "$session" enter
      sleep 4
      ;;

    rapid-updates)
      sleep 8
      ;;
  esac

  # Collect profiling stats
  echo "" >> "$result_file"
  echo "=== PROFILING STATS ===" >> "$result_file"
  tui-wright type "$session" "/profile stats"
  tui-wright key "$session" enter
  sleep 1
  # Scroll down to see stats output
  for i in $(seq 1 200); do
    tui-wright mouse "$session" scrolldown 50 15
  done
  sleep 1
  tui-wright screen "$session" >> "$result_file" 2>&1

  # Export trace
  tui-wright type "$session" "/profile dump"
  tui-wright key "$session" enter
  sleep 1

  # Capture final screen
  echo "" >> "$result_file"
  echo "=== FINAL SCREEN ===" >> "$result_file"
  tui-wright screen "$session" >> "$result_file" 2>&1

  # Clean up
  tui-wright key "$session" ctrl+c
  sleep 1
  tui-wright kill "$session" 2>/dev/null || true

  # Copy profile trace if exists
  local latest_profile
  latest_profile=$(ls -t "$PROJECT"/.gent/profile-*.json 2>/dev/null | head -1 || true)
  if [[ -n "$latest_profile" ]]; then
    cp "$latest_profile" "$RESULTS_DIR/${profile_prefix}-trace.json"
    echo "Profile trace: $RESULTS_DIR/${profile_prefix}-trace.json"
  fi

  echo "Results: $result_file"
  echo "=== Done: $name ==="
  echo ""
}

# Build first
echo "Building gent..."
cd "$PROJECT"
cargo build 2>&1

if [[ "$TEST_NAME" == "all" ]]; then
  for test in massive-scrollback heavy-markdown-stream thinking-blocks rapid-updates; do
    run_benchmark "$test" || echo "WARNING: $test failed"
  done
else
  run_benchmark "$TEST_NAME"
fi

echo ""
echo "All benchmarks complete. Results in: $RESULTS_DIR/"
ls -la "$RESULTS_DIR/"
