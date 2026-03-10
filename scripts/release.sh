#!/usr/bin/env bash
set -euo pipefail

# Release script for gent
# Usage: scripts/release.sh <version>
# Example: scripts/release.sh 0.1.0

VERSION="${1:-}"

if [ -z "$VERSION" ]; then
  echo "Usage: scripts/release.sh <version>"
  echo "Example: scripts/release.sh 0.1.0"
  exit 1
fi

# Strip leading 'v' if provided
VERSION="${VERSION#v}"
TAG="v${VERSION}"

echo "==> Releasing gent ${TAG}"

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: working tree has uncommitted changes"
  exit 1
fi

# Check we're on main
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
  echo "Warning: releasing from branch '$BRANCH' (not main)"
  read -p "Continue? [y/N] " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# Bump version in Cargo.toml
echo "==> Bumping Cargo.toml to ${VERSION}"
sed -i.bak "s/^version = \".*\"/version = \"${VERSION}\"/" Cargo.toml
rm -f Cargo.toml.bak

# Bump version in flake.nix
echo "==> Bumping flake.nix to ${VERSION}"
sed -i.bak "s/version = \"[0-9]*\.[0-9]*\.[0-9]*\";/version = \"${VERSION}\";/g" flake.nix
rm -f flake.nix.bak

# Update Cargo.lock
echo "==> Updating Cargo.lock"
cargo check --quiet 2>/dev/null || true

# Verify build and tests
echo "==> Verifying build and tests"
cargo build
janet janet/test/run.janet

# Update CHANGELOG.md
if command -v git-cliff &>/dev/null; then
  echo "==> Updating CHANGELOG.md"
  git-cliff --config cliff.toml --output CHANGELOG.md
fi

# Commit and tag
echo "==> Committing version bump"
git add Cargo.toml Cargo.lock flake.nix CHANGELOG.md
git commit -m "release: ${TAG}"

echo "==> Creating tag ${TAG}"
git tag -a "${TAG}" -m "Release ${TAG}"

echo "==> Pushing to origin"
git push origin "${BRANCH}"
git push origin "${TAG}"

echo ""
echo "Done! ${TAG} pushed. The release workflow will build binaries and create a GitHub Release."
