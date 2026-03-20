#!/usr/bin/env bash
# test/twin-all.sh — Run all digital twin tests (unit + E2E).
#
# Usage: bash test/twin-all.sh
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#   - docker compose
#   - python3 + pip (fastapi, pytest, httpx)
#   - janet on PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

run_section() {
  local label="$1"
  shift
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  $label"
  echo "══════════════════════════════════════════════════════════"
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  ^^^ FAILED ^^^"
  fi
}

# ── Python unit tests ───────────────────────────────────────────

run_section "Python twin unit tests (pytest)" \
  python3 -m pytest "$PROJECT/twins/tests/" -v

# ── Janet auth/refresh tests ────────────────────────────────────

run_section "Janet tests (includes auth retry + token refresh)" \
  janet "$PROJECT/janet/test/run.janet"

# ── Build gent ──────────────────────────────────────────────────

if [ ! -f "$PROJECT/target/debug/gent" ]; then
  echo ""
  echo "Building gent..."
  (cd "$PROJECT" && cargo build)
fi

# ── Start twin containers ──────────────────────────────────────

echo ""
echo "Ensuring twin containers are up..."
docker compose -f "$PROJECT/twins/docker-compose.yml" up -d --wait

# ── Twin E2E tests ──────────────────────────────────────────────

run_section "E2E: full round-trip"        bash "$SCRIPT_DIR/twin-e2e.sh"
run_section "E2E: auth verification"      bash "$SCRIPT_DIR/twin-auth.sh"
run_section "E2E: provider switching"     bash "$SCRIPT_DIR/twin-provider-switch.sh"
run_section "E2E: error handling"         bash "$SCRIPT_DIR/twin-error-handling.sh"
run_section "E2E: error scenarios"        bash "$SCRIPT_DIR/twin-error-scenarios.sh"
run_section "E2E: OAuth PKCE login"       bash "$SCRIPT_DIR/twin-oauth.sh"

# ── Results ─────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  All DTU tests: $TOTAL sections, $PASS passed, $FAIL failed"
echo "══════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
