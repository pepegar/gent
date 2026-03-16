#!/usr/bin/env bash
# test/install.sh — smoke tests for docs/install.sh using mocked release downloads.
#
# Verifies the installer against locally generated release assets so PR CI can
# exercise install flows without depending on real GitHub releases.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT/docs/install.sh"
GENT="$ROOT/target/debug/gent"
HOST_UNAME_S="$(/usr/bin/uname -s)"
HOST_UNAME_M="$(/usr/bin/uname -m)"

PASS=0
FAIL=0

pass() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

assert_file() {
  local path="$1"
  local label="$2"
  if [ -f "$path" ]; then
    pass "$label"
  else
    fail "$label (missing $path)"
  fi
}

assert_output() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -Fq "$pattern" "$file"; then
    pass "$label"
  else
    echo "  Output:"
    sed 's/^/    /' "$file"
    fail "$label (missing '$pattern')"
  fi
}

host_asset_name() {
  local os arch target
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$arch" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64) arch="x86_64" ;;
    *) echo "Unsupported architecture: $arch" >&2; return 1 ;;
  esac

  case "$os" in
    Darwin) target="${arch}-apple-darwin" ;;
    Linux) target="${arch}-unknown-linux-musl" ;;
    *) echo "Unsupported OS: $os" >&2; return 1 ;;
  esac

  printf 'gent-%s.tar.gz\n' "$target"
}

ensure_binary() {
  if [ ! -x "$GENT" ]; then
    cargo build
  fi
}

write_mock_curl() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
write_fmt=""
url=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -w)
      write_fmt="$2"
      shift 2
      ;;
    -s|-S|-f|-L|-sS|-sSf|-sSL|-sSfL)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

printf '%s\n' "$url" >> "$MOCK_CURL_LOG"

render_body() {
  local body="$1"
  if [ -n "$output" ]; then
    printf '%s' "$body" > "$output"
  else
    printf '%s' "$body"
  fi
}

render_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    if [ -n "$write_fmt" ]; then
      printf '%s' "${write_fmt//\%\{http_code\}/404}"
      exit 0
    fi
    exit 22
  fi

  if [ -n "$output" ]; then
    cp "$file" "$output"
  else
    cat "$file"
  fi

  if [ -n "$write_fmt" ]; then
    printf '%s' "${write_fmt//\%\{http_code\}/200}"
  fi
}

case "$url" in
  "https://api.github.com/repos/pepegar/gent/releases/latest")
    if [ "${MOCK_LATEST_MODE:-tag}" = "empty" ]; then
      render_body '{}'
    else
      render_body "{\"tag_name\":\"${MOCK_STABLE_TAG}\"}"
    fi
    ;;
  "https://github.com/pepegar/gent/releases/download/"*)
    rest="${url#https://github.com/pepegar/gent/releases/download/}"
    tag="${rest%%/*}"
    filename="${rest#*/}"
    render_file "$MOCK_RELEASES_DIR/$tag/$filename"
    ;;
  *)
    echo "mock curl: unsupported URL $url" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$path"
}

write_mock_uname() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -s) printf '%s\n' "${MOCK_UNAME_S}" ;;
  -m) printf '%s\n' "${MOCK_UNAME_M}" ;;
  *) exec /usr/bin/uname "$@" ;;
esac
EOF
  chmod +x "$path"
}

write_mock_mv() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

dest="${!#}"
if [ -n "${MOCK_PROTECTED_PREFIX:-}" ] && [[ "$dest" == "$MOCK_PROTECTED_PREFIX"* ]] && [ "${SUDO_MODE:-0}" != "1" ]; then
  exit 1
fi

exec /bin/mv "$@"
EOF
  chmod +x "$path"
}

write_mock_chmod() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${!#}"
if [ -n "${MOCK_PROTECTED_PREFIX:-}" ] && [[ "$target" == "$MOCK_PROTECTED_PREFIX"* ]] && [ "${SUDO_MODE:-0}" != "1" ]; then
  exit 1
fi

exec /bin/chmod "$@"
EOF
  chmod +x "$path"
}

write_mock_sudo() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

last_arg="${!#}"
if [ -n "${MOCK_PROTECTED_PREFIX:-}" ] && [[ "$last_arg" == "$MOCK_PROTECTED_PREFIX"* ]]; then
  parent="$(dirname "$last_arg")"
  while [ "$parent" != "/" ] && [[ "$parent" == "$MOCK_PROTECTED_PREFIX"* ]]; do
    /bin/chmod u+w "$parent" 2>/dev/null || true
    parent="$(dirname "$parent")"
  done
fi

if [ "${1:-}" = "mkdir" ]; then
  env SUDO_MODE=1 "$@"
  if [ -d "$last_arg" ] && [ -n "${MOCK_PROTECTED_PREFIX:-}" ] && [[ "$last_arg" == "$MOCK_PROTECTED_PREFIX"* ]]; then
    /bin/chmod 555 "$last_arg"
  fi
  exit 0
fi

exec env SUDO_MODE=1 "$@"
EOF
  chmod +x "$path"
}

setup_fixtures() {
  local workdir="$1"
  local asset="$2"
  local stable_dir="$workdir/releases/v9.9.9"
  local nightly_dir="$workdir/releases/nightly"
  local tmpdir

  mkdir -p "$stable_dir" "$nightly_dir"
  tmpdir="$(mktemp -d)"

  cp "$GENT" "$tmpdir/gent"
  tar czf "$stable_dir/$asset" -C "$tmpdir" gent
  cp "$stable_dir/$asset" "$nightly_dir/$asset"

  (
    cd "$stable_dir"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$asset" > checksums.txt
    else
      shasum -a 256 "$asset" | awk '{print $1 "  " $2}' > checksums.txt
    fi
  )
  cp "$stable_dir/checksums.txt" "$nightly_dir/checksums.txt"

  rm -rf "$tmpdir"
}

setup_mocks() {
  local workdir="$1"
  mkdir -p "$workdir/mock-bin"
  : > "$workdir/curl.log"
  write_mock_curl "$workdir/mock-bin/curl"
  write_mock_uname "$workdir/mock-bin/uname"
  write_mock_mv "$workdir/mock-bin/mv"
  write_mock_chmod "$workdir/mock-bin/chmod"
  write_mock_sudo "$workdir/mock-bin/sudo"
}

run_installer() {
  local workdir="$1"
  shift
  PATH="$workdir/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MOCK_CURL_LOG="$workdir/curl.log" \
  MOCK_RELEASES_DIR="$workdir/releases" \
  MOCK_STABLE_TAG="v9.9.9" \
  MOCK_UNAME_S="$HOST_UNAME_S" \
  MOCK_UNAME_M="$HOST_UNAME_M" \
  sh "$INSTALL_SCRIPT" "$@"
}

test_stable_install() {
  local workdir outdir output
  workdir="$(mktemp -d)"
  outdir="$workdir/bin"
  output="$workdir/output.log"

  setup_fixtures "$workdir" "$(host_asset_name)"
  setup_mocks "$workdir"

  if run_installer "$workdir" --to "$outdir" >"$output" 2>&1 && "$outdir/gent" --version >>"$output" 2>&1; then
    assert_file "$outdir/gent" "stable install writes gent into custom dir"
    assert_output "$output" "channel" "stable install reports selected channel"
    assert_output "$output" "stable (v9.9.9)" "stable install resolves the mocked stable release"
  else
    sed 's/^/    /' "$output"
    fail "stable install completes successfully"
  fi

  rm -rf "$workdir"
}

test_nightly_install() {
  local workdir outdir output
  workdir="$(mktemp -d)"
  outdir="$workdir/bin"
  output="$workdir/output.log"

  setup_fixtures "$workdir" "$(host_asset_name)"
  setup_mocks "$workdir"

  if run_installer "$workdir" --nightly --to "$outdir" >"$output" 2>&1 && "$outdir/gent" --version >>"$output" 2>&1; then
    assert_file "$outdir/gent" "nightly install writes gent into custom dir"
    assert_output "$output" "nightly" "nightly install reports nightly channel"
  else
    sed 's/^/    /' "$output"
    fail "nightly install completes successfully"
  fi

  rm -rf "$workdir"
}

test_stable_falls_back_to_nightly() {
  local workdir outdir output
  workdir="$(mktemp -d)"
  outdir="$workdir/bin"
  output="$workdir/output.log"

  setup_fixtures "$workdir" "$(host_asset_name)"
  setup_mocks "$workdir"

  if MOCK_LATEST_MODE=empty run_installer "$workdir" --to "$outdir" >"$output" 2>&1; then
    assert_output "$output" "falling back to nightly" "stable install falls back when latest release is unavailable"
    assert_output "$workdir/curl.log" "/releases/download/nightly/" "fallback downloads the nightly asset"
  else
    sed 's/^/    /' "$output"
    fail "stable fallback install completes successfully"
  fi

  rm -rf "$workdir"
}

test_protected_install_uses_sudo_path() {
  local workdir protected_root output
  workdir="$(mktemp -d)"
  protected_root="$workdir/protected"
  output="$workdir/output.log"

  setup_fixtures "$workdir" "$(host_asset_name)"
  setup_mocks "$workdir"

  mkdir -p "$protected_root"
  /bin/chmod 555 "$protected_root"

  if MOCK_PROTECTED_PREFIX="$protected_root" run_installer "$workdir" --to "$protected_root/bin" >"$output" 2>&1; then
    assert_file "$protected_root/bin/gent" "protected install writes gent after sudo escalation"
    assert_output "$output" "need sudo for: mkdir -p $protected_root/bin" "protected install escalates for directory creation"
    assert_output "$output" "need sudo for: mv " "protected install escalates for binary move"
    assert_output "$output" "need sudo for: chmod +x $protected_root/bin/gent" "protected install escalates for chmod"
  else
    sed 's/^/    /' "$output"
    fail "protected install completes successfully"
  fi

  /bin/chmod 755 "$protected_root" "$protected_root/bin" 2>/dev/null || true
  rm -rf "$workdir"
}

echo "── installer smoke tests ──"
ensure_binary

test_stable_install
test_nightly_install
test_stable_falls_back_to_nightly
test_protected_install_uses_sudo_path

echo ""
echo "═══ Results: $((PASS + FAIL)) checks, $PASS passed, $FAIL failed ═══"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
