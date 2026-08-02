#!/bin/bash
#
# Builds Strata, signs it, packages a DMG and notarises it.
#
# Every step past the build is optional and degrades on its own: without a
# Developer ID certificate you still get a working .app and .dmg, just one that
# Gatekeeper will warn about on another Mac. That is deliberate — the project
# has to stay buildable by anyone who clones it, not only by whoever holds the
# signing key.
#
#   ./Scripts/release.sh                 # build + DMG, signed if possible
#   ./Scripts/release.sh --notarize      # also submit to Apple (needs a profile)
#
# Notarisation expects credentials stored once, under this profile name:
#   xcrun notarytool store-credentials strata-notary \
#     --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PASSWORD
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Strata"
BUILD_DIR="build"
NOTARY_PROFILE="${NOTARY_PROFILE:-strata-notary}"
NOTARIZE=false
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=true

say() { printf "\033[1m▸ %s\033[0m\n" "$1"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$1"; }

# --- Version, from the tag if we are on one -----------------------------------

VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo '0.1.0')"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
say "Version $VERSION (build $BUILD_NUMBER)"

# --- Tests before anything else ------------------------------------------------

say "Tests du moteur"
(cd DiskCore && swift test --skip firmlinks 2>&1 | tail -1)

# --- Build ---------------------------------------------------------------------

say "Génération du projet"
command -v xcodegen >/dev/null || { echo "xcodegen absent : brew install xcodegen"; exit 1; }
xcodegen generate --quiet

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

say "Compilation"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build 2>&1 | grep -E "error:|warning: .*deprecated|BUILD" || true

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "Compilation échouée"; exit 1; }

# --- Signing -------------------------------------------------------------------

# Only a "Developer ID Application" certificate produces something another Mac
# will run. "Apple Development" certificates are for local debugging and are
# rejected by Gatekeeper elsewhere, so they are deliberately not accepted here.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 \
  | sed -E 's/.*"(.*)"/\1/' || true)"

if [[ -n "$IDENTITY" ]]; then
  say "Signature — $IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
  warn "Aucun certificat « Developer ID Application » : build non signée."
  warn "Elle fonctionne ici, mais un autre Mac affichera un avertissement."
  warn "Il faut l'adhésion au programme développeur Apple (99 €/an)."
fi

# --- DMG -----------------------------------------------------------------------

say "Création du DMG"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$DMG_PATH"

# --- Notarisation --------------------------------------------------------------

if $NOTARIZE; then
  if [[ -z "$IDENTITY" ]]; then
    warn "Notarisation impossible sans signature — étape ignorée."
  else
    say "Notarisation (plusieurs minutes)"
    xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    say "Vérification Gatekeeper"
    spctl -a -vvv --type install "$DMG_PATH" || true
  fi
fi

SIZE="$(du -h "$DMG_PATH" | cut -f1)"
SHA="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
say "Terminé : $DMG_PATH ($SIZE)"
echo "sha256: $SHA"
