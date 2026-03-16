#!/usr/bin/env bash
# test/install-live.sh — install gent from the public installer and verify it runs.
#
# Usage:
#   bash test/install-live.sh
#   bash test/install-live.sh --nightly

set -euo pipefail

INSTALLER_URL="${INSTALLER_URL:-https://try.gent/install.sh}"
INSTALL_ATTEMPTS="${INSTALL_ATTEMPTS:-6}"
INSTALL_RETRY_DELAY="${INSTALL_RETRY_DELAY:-10}"

WORKDIR="$(mktemp -d)"
TARGET_DIR="$WORKDIR/bin"
LOG_FILE="$WORKDIR/install.log"

cleanup() {
  rm -rf "$WORKDIR"
}

trap cleanup EXIT

run_install() {
  rm -rf "$TARGET_DIR"
  mkdir -p "$TARGET_DIR"
  curl -fsSL "$INSTALLER_URL" | sh -s -- --to "$TARGET_DIR" "$@"
}

echo "── live installer smoke test ──"
echo "Installer: $INSTALLER_URL"
echo "Args: ${*:-<none>}"

attempt=1
while true; do
  if run_install "$@" >"$LOG_FILE" 2>&1; then
    break
  fi

  if [ "$attempt" -ge "$INSTALL_ATTEMPTS" ]; then
    echo "Installer failed after $attempt attempts"
    sed 's/^/  /' "$LOG_FILE"
    exit 1
  fi

  echo "Attempt $attempt failed; retrying in ${INSTALL_RETRY_DELAY}s"
  sed 's/^/  /' "$LOG_FILE"
  attempt=$((attempt + 1))
  sleep "$INSTALL_RETRY_DELAY"
done

sed 's/^/  /' "$LOG_FILE"
"$TARGET_DIR/gent" --version
