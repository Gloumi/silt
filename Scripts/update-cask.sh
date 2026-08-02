#!/bin/bash
#
# Points the Homebrew cask at a published release.
#
#   ./Scripts/update-cask.sh            # latest release on GitHub
#   ./Scripts/update-cask.sh v0.2.0     # a specific tag
#
# Run it after the release workflow has published the DMG — it downloads the
# asset to checksum it, so the release has to exist. The checksum is taken from
# the artefact people will actually install, never from a local build, because
# those two are only identical by luck.
#
set -euo pipefail

cd "$(dirname "$0")/.."

REPO="Gloumi/silt"
CASK="Casks/silt.rb"

command -v gh >/dev/null || { echo "gh absent : brew install gh"; exit 1; }

TAG="${1:-$(gh release view --repo "$REPO" --json tagName -q .tagName)}"
VERSION="${TAG#v}"
DMG="Silt-$VERSION.dmg"

echo "▸ $TAG"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh release download "$TAG" --repo "$REPO" --pattern "$DMG" --dir "$TMP"

SHA="$(shasum -a 256 "$TMP/$DMG" | cut -d' ' -f1)"
echo "  sha256 $SHA"

# Anchored to the field name so a matching hex string elsewhere is left alone.
sed -i '' \
  -e "s|^  version \".*\"|  version \"$VERSION\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
  "$CASK"

grep -E '^  (version|sha256) ' "$CASK"
echo "▸ $CASK à jour — reste à committer."
