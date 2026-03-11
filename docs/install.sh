#!/bin/sh
# gent installer — https://try.gent
# Usage:
#   curl -sSf https://try.gent/install.sh | sh
#   curl -sSf https://try.gent/install.sh | sh -s -- --nightly
#   curl -sSf https://try.gent/install.sh | sh -s -- --to ~/.local/bin

set -eu

REPO="pepegar/gent"
INSTALL_DIR="/usr/local/bin"
CHANNEL="stable"

# --- parse flags ---

while [ $# -gt 0 ]; do
  case "$1" in
    --nightly) CHANNEL="nightly"; shift ;;
    --to)      INSTALL_DIR="$2"; shift 2 ;;
    *)         echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- helpers ---

say()  { printf "  \033[1;32m%s\033[0m %s\n" "$1" "$2"; }
err()  { printf "  \033[1;31merror:\033[0m %s\n" "$1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "need '$1' (not found in PATH)"; }

need curl
need tar

# --- detect platform ---

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) ;;
  Linux)  ;;
  *)      err "Unsupported OS: $OS (only macOS and Linux are supported)" ;;
esac

case "$ARCH" in
  arm64|aarch64) ARCH="aarch64" ;;
  x86_64|amd64)  ARCH="x86_64" ;;
  *)              err "Unsupported architecture: $ARCH" ;;
esac

case "$OS" in
  Darwin) TARGET="${ARCH}-apple-darwin" ;;
  Linux)  TARGET="${ARCH}-unknown-linux-musl" ;;
esac

ASSET="gent-${TARGET}.tar.gz"

say "detect" "$OS $ARCH → $TARGET"

# --- resolve download URL ---

if [ "$CHANNEL" = "nightly" ]; then
  TAG="nightly"
  say "channel" "nightly"
else
  # get the latest non-prerelease tag
  TAG=$(curl -sSf "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*: *"//;s/".*//' || true)

  if [ -z "$TAG" ]; then
    say "channel" "no stable release found, falling back to nightly"
    TAG="nightly"
  else
    say "channel" "stable ($TAG)"
  fi
fi

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

# --- download & verify ---

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

say "download" "$URL"
HTTP_CODE=$(curl -sSL -w "%{http_code}" -o "${TMPDIR}/${ASSET}" "$URL")

if [ "$HTTP_CODE" != "200" ]; then
  err "Download failed (HTTP $HTTP_CODE). Asset may not exist for $TARGET in release $TAG."
fi

# verify checksum if available
CHECKSUM_URL="https://github.com/${REPO}/releases/download/${TAG}/checksums.txt"
if curl -sSfL -o "${TMPDIR}/checksums.txt" "$CHECKSUM_URL" 2>/dev/null; then
  say "verify" "checking sha256"
  cd "$TMPDIR"
  if command -v sha256sum >/dev/null 2>&1; then
    grep "$ASSET" checksums.txt | sha256sum -c --quiet - || err "Checksum verification failed!"
  elif command -v shasum >/dev/null 2>&1; then
    EXPECTED=$(grep "$ASSET" checksums.txt | awk '{print $1}')
    ACTUAL=$(shasum -a 256 "$ASSET" | awk '{print $1}')
    [ "$EXPECTED" = "$ACTUAL" ] || err "Checksum verification failed!"
  fi
  cd - >/dev/null
fi

# --- extract & install ---

say "extract" "$ASSET"
tar xzf "${TMPDIR}/${ASSET}" -C "$TMPDIR"

# helper: run a command, escalating to sudo only if needed
run_escalated() {
  if "$@" 2>/dev/null; then
    return 0
  elif command -v sudo >/dev/null 2>&1; then
    say "install" "need sudo for: $*"
    sudo "$@"
  else
    err "Permission denied and sudo not available. Try: $*"
  fi
}

# ensure install directory exists
if [ ! -d "$INSTALL_DIR" ]; then
  run_escalated mkdir -p "$INSTALL_DIR"
fi

# move binary into place
if [ -w "$INSTALL_DIR" ]; then
  mv "${TMPDIR}/gent" "${INSTALL_DIR}/gent"
else
  run_escalated mv "${TMPDIR}/gent" "${INSTALL_DIR}/gent"
fi

chmod +x "${INSTALL_DIR}/gent"

say "done" "gent installed to ${INSTALL_DIR}/gent"
echo ""
echo "  Run 'gent' to start."
echo ""
