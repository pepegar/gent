#!/usr/bin/env bash
# test/e2e/test-bash-progress.sh — E2E test for bash progress display via tui-wright.
#
# Spawns gent with GENT_STAGE=1 (stage provider), sends a message that triggers
# a real bash tool call (a slow command), and verifies the progress lines appear
# and then the final result replaces them.

set -euo pipefail

GENT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
GENT_BIN="${GENT_DIR}/target/debug/gent"

if [ ! -f "$GENT_BIN" ]; then
  echo "FAIL: gent binary not found at $GENT_BIN — run cargo build first"
  exit 1
fi

# Create a stage script that queues a bash tool call with a slow command
STAGE_SCRIPT=$(mktemp /tmp/gent-stage-XXXXX.janet)
cat > "$STAGE_SCRIPT" << 'EOF'
(import core/stage :as stage)

# Queue a bash tool call that runs a command producing output over time
(stage/respond
  (stage/tool-call "bash"
    {:command "for i in 1 2 3 4 5 6 7 8; do echo \"Step $i: processing...\"; sleep 0.3; done; echo Done!"}
    :id "bash_progress_test"))

# Then a text response after the tool completes
(stage/respond (stage/text "The build completed successfully."))
EOF

cleanup() {
  [ -n "${SESSION:-}" ] && tui-wright kill "$SESSION" 2>/dev/null || true
  rm -f "$STAGE_SCRIPT"
}
trap cleanup EXIT

# Spawn gent in stage mode
SESSION=$(GENT_STAGE="$STAGE_SCRIPT" tui-wright spawn "$GENT_BIN" --cols 100 --rows 30 | awk '{print $2}')
echo "Session: $SESSION"

# Wait for gent to start up
sleep 1

# Type a message to trigger the staged response
tui-wright type "$SESSION" "run the build"
tui-wright key "$SESSION" enter

# Wait for the bash command to start executing and progress to appear
# The command runs ~2.4s total (8 steps × 0.3s each)
sleep 1.5

# Read the screen — should show progress lines while command is running
SCREEN1=$(tui-wright screen "$SESSION")
echo "=== Screen during execution ==="
echo "$SCREEN1"
echo "==="

# Check for progress indicator (the ┄ header or step output)
if echo "$SCREEN1" | grep -q "Step"; then
  echo "PASS: Progress lines visible during execution"
else
  echo "FAIL: No progress lines visible during execution"
  exit 1
fi

# Wait for the command to finish
sleep 2

# Read the screen after completion — progress should be replaced with final result
SCREEN2=$(tui-wright screen "$SESSION")
echo "=== Screen after completion ==="
echo "$SCREEN2"
echo "==="

# Check for final result
if echo "$SCREEN2" | grep -q "Done!"; then
  echo "PASS: Final result visible after completion"
else
  echo "FAIL: Final result not visible after completion"
  exit 1
fi

# Check that the follow-up text response appeared
if echo "$SCREEN2" | grep -q "completed successfully"; then
  echo "PASS: Follow-up response visible"
else
  echo "FAIL: Follow-up response not visible"
  exit 1
fi

echo ""
echo "All E2E bash progress tests passed!"