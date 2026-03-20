#!/usr/bin/env bash
# test/twin-oauth.sh — OAuth PKCE login flow E2E test via digital twin.
#
# Verifies the full OAuth login flow:
#   1. /login command triggers PKCE generation and shows auth URL
#   2. User pastes authorization code
#   3. gent exchanges code for tokens at twin's /v1/oauth/token
#   4. Token is stored and used for subsequent API calls
#
# Prerequisites:
#   - cargo build (gent binary at target/debug/gent)
#   - tui-wright on PATH
#   - docker compose (twins at twins/docker-compose.yml)
#   - curl and jq on PATH
#
# Usage: bash test/twin-oauth.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"

GENT="$PROJECT/target/debug/gent"
COLS=120
ROWS=30
PASS=0
FAIL=0

ANTHROPIC_TWIN="http://localhost:18080"
TWIN_API_URL="$ANTHROPIC_TWIN/v1/messages"
TWIN_TOKEN_URL="$ANTHROPIC_TWIN/v1/oauth/token"

SID=""
FAKE_HOME=""

# ── Helpers ───────────────────────────────────────────────────

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

assert_screen_contains() {
  local sid="$1"
  local expected="$2"
  local label="$3"
  local timeout="${4:-15000}"
  if tui-wright wait-for "$sid" "$expected" --timeout "$timeout" > /dev/null 2>&1; then
    pass "$label"
  else
    echo "  Screen contents:"
    tui-wright screen "$sid" 2>/dev/null | tail -15
    fail "$label (expected '$expected')"
  fi
}

cleanup() {
  if [[ -n "$SID" ]]; then
    tui-wright kill "$SID" 2>/dev/null || true
  fi
  if [[ -n "$FAKE_HOME" ]]; then
    rm -rf "$FAKE_HOME"
  fi
}
trap cleanup EXIT

ensure_twins_up() {
  if curl -sf "$ANTHROPIC_TWIN/__control/health" > /dev/null 2>&1; then
    echo "Anthropic twin already healthy."
    return
  fi
  echo "Starting twin containers..."
  docker compose -f "$PROJECT/twins/docker-compose.yml" up -d --wait
  for i in $(seq 1 15); do
    if curl -sf "$ANTHROPIC_TWIN/__control/health" > /dev/null 2>&1; then
      echo "Anthropic twin is healthy."
      return
    fi
    sleep 1
  done
  echo "FATAL: Anthropic twin did not become healthy"
  exit 1
}

kill_gent() {
  if [[ -n "$SID" ]]; then
    tui-wright kill "$SID" 2>/dev/null || true
    SID=""
  fi
}

# ── Build ─────────────────────────────────────────────────────

echo "── twin-oauth: OAuth PKCE login flow E2E test ──"

if [ ! -f "$GENT" ]; then
  echo "Building gent..."
  (cd "$PROJECT" && cargo build 2>&1)
fi

ensure_twins_up

# ══════════════════════════════════════════════════════════════
# Test 1: Full OAuth login flow with token exchange
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Part 1: OAuth login flow ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

FAKE_HOME=$(mktemp -d)

# Spawn gent with no API key — force OAuth login
# Point token URL at the twin, API URL at the twin
SID_LINE=$(HOME="$FAKE_HOME" \
  GENT_API_URL="$TWIN_API_URL" \
  GENT_OAUTH_TOKEN_URL="$TWIN_TOKEN_URL" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS" -- -q)
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

# Run /login command
echo "Running /login..."
tui-wright type "$SID" "/login"
tui-wright key "$SID" enter

# Wait for the selector to appear (shows provider list)
assert_screen_contains "$SID" "Login" "login: selector appears" 5000

# Press Enter to select the first provider (anthropic)
tui-wright key "$SID" enter

# Wait for the auth URL and token prompt to appear
assert_screen_contains "$SID" "Opening browser for Anthropic" "login: auth URL displayed" 5000
assert_screen_contains "$SID" "token:" "login: token prompt appears" 5000

# Type a fake authorization code (code#state format)
echo "Typing auth code..."
tui-wright type "$SID" "fake-auth-code-12345#fake-state-67890"
tui-wright key "$SID" enter

# Wait for successful login confirmation
assert_screen_contains "$SID" "Logged in" "login: success message appears" 10000

# ══════════════════════════════════════════════════════════════
# Test 2: Verify token exchange request was captured by twin
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Part 2: Verify token exchange ──"

REQUESTS=$(curl -sf "$ANTHROPIC_TWIN/__control/requests")

# Find the oauth_token request
OAUTH_REQ=$(echo "$REQUESTS" | jq '[.[] | select(.endpoint == "oauth_token")] | .[0]')

if [[ "$OAUTH_REQ" != "null" ]] && [[ -n "$OAUTH_REQ" ]]; then
  pass "token exchange: request was captured by twin"

  # Verify grant_type
  GRANT_TYPE=$(echo "$OAUTH_REQ" | jq -r '.body.grant_type')
  if [[ "$GRANT_TYPE" == "authorization_code" ]]; then
    pass "token exchange: grant_type is authorization_code"
  else
    fail "token exchange: grant_type is '$GRANT_TYPE', expected 'authorization_code'"
  fi

  # Verify the auth code was sent
  CODE=$(echo "$OAUTH_REQ" | jq -r '.body.code')
  if [[ "$CODE" == "fake-auth-code-12345" ]]; then
    pass "token exchange: authorization code was sent correctly"
  else
    fail "token exchange: code is '$CODE', expected 'fake-auth-code-12345'"
  fi

  # Verify code_verifier is present and non-empty (PKCE proof)
  CODE_VERIFIER=$(echo "$OAUTH_REQ" | jq -r '.body.code_verifier')
  if [[ -n "$CODE_VERIFIER" ]] && [[ "$CODE_VERIFIER" != "null" ]] && [[ "$CODE_VERIFIER" != "" ]]; then
    pass "token exchange: code_verifier (PKCE) is present and non-empty"
  else
    fail "token exchange: code_verifier is missing or empty"
  fi

  # Verify client_id
  CLIENT_ID=$(echo "$OAUTH_REQ" | jq -r '.body.client_id')
  if [[ "$CLIENT_ID" == "9d1c250a-e61b-44d9-88ed-5944d1962f5e" ]]; then
    pass "token exchange: client_id matches Anthropic OAuth client"
  else
    fail "token exchange: client_id is '$CLIENT_ID'"
  fi
else
  fail "token exchange: no oauth_token request captured"
  echo "  All requests: $REQUESTS"
fi

# ══════════════════════════════════════════════════════════════
# Test 3: Use the OAuth token for an API call
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Part 3: API call with OAuth token ──"

# Reset to clear old requests but keep the session
curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

# Enqueue a response for the next API call
curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"OAuth token works!"}' > /dev/null

# Send a message — gent should use the OAuth token from login
tui-wright type "$SID" "Test OAuth token"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "OAuth token works!" "oauth api call: response appears" 15000

# Verify the Bearer token was used
API_REQUESTS=$(curl -sf "$ANTHROPIC_TWIN/__control/requests")
AUTH_HEADER=$(echo "$API_REQUESTS" | jq -r '.[0].headers.authorization // empty')

if [[ "$AUTH_HEADER" == Bearer\ twin-access-* ]]; then
  pass "oauth api call: Bearer token from OAuth flow was used"
else
  fail "oauth api call: unexpected auth header: '$AUTH_HEADER'"
  echo "  Expected: Bearer twin-access-<uuid>"
  echo "  Headers: $(echo "$API_REQUESTS" | jq '.[0].headers')"
fi

kill_gent

# ══════════════════════════════════════════════════════════════
# Test 4: OAuth token refresh
# ══════════════════════════════════════════════════════════════

echo ""
echo "── Part 4: OAuth token refresh on 401 ──"

curl -sf -X POST "$ANTHROPIC_TWIN/__control/reset" > /dev/null

# Manually set an expired OAuth credential in auth.json
mkdir -p "$FAKE_HOME/.gent"
cat > "$FAKE_HOME/.gent/auth.json" <<'AUTHJSON'
{
  "anthropic": {
    "type": "oauth",
    "access": "expired-token",
    "refresh": "twin-refresh-for-test",
    "expires": 0
  }
}
AUTHJSON

# Enqueue a success response (after the auto-refresh, gent retries)
curl -sf -X POST "$ANTHROPIC_TWIN/__control/enqueue" \
  -H "Content-Type: application/json" \
  -d '{"type":"text","content":"Refreshed token works!"}' > /dev/null

# Spawn a fresh gent — it will load the expired token from auth.json
SID_LINE=$(HOME="$FAKE_HOME" \
  GENT_API_URL="$TWIN_API_URL" \
  GENT_OAUTH_TOKEN_URL="$TWIN_TOKEN_URL" \
  tui-wright spawn "$GENT" --cols "$COLS" --rows "$ROWS" -- -q)
SID=$(echo "$SID_LINE" | sed 's/session: //')
echo "Session: $SID"

if ! tui-wright wait-for "$SID" "focus:" --timeout 15000 > /dev/null 2>&1; then
  echo "FATAL: gent did not start within timeout"
  tui-wright screen "$SID" 2>/dev/null
  exit 1
fi

# Send a message — gent should auto-refresh the expired token before/during the call
tui-wright type "$SID" "Test with expired token"
tui-wright key "$SID" enter

assert_screen_contains "$SID" "Refreshed token works!" "token refresh: response appears after auto-refresh" 15000

# Verify the refresh happened — check requests for a refresh_token grant
REFRESH_REQUESTS=$(curl -sf "$ANTHROPIC_TWIN/__control/requests")
REFRESH_REQ=$(echo "$REFRESH_REQUESTS" | jq '[.[] | select(.endpoint == "oauth_token" and .body.grant_type == "refresh_token")] | .[0]')

if [[ "$REFRESH_REQ" != "null" ]] && [[ -n "$REFRESH_REQ" ]]; then
  pass "token refresh: refresh_token grant was sent to twin"

  REFRESH_TOKEN=$(echo "$REFRESH_REQ" | jq -r '.body.refresh_token')
  if [[ "$REFRESH_TOKEN" == "twin-refresh-for-test" ]]; then
    pass "token refresh: correct refresh_token was sent"
  else
    fail "token refresh: refresh_token is '$REFRESH_TOKEN', expected 'twin-refresh-for-test'"
  fi
else
  fail "token refresh: no refresh_token request captured"
  echo "  All requests: $(echo "$REFRESH_REQUESTS" | jq '.')"
fi

kill_gent

# ── Results ───────────────────────────────────────────────────

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
