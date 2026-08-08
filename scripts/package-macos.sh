#!/bin/zsh

# Build a distributable macOS release of the Swift Magi app, which provides
# Option-click Reader mode and the Semi-Code Editor.
# Produces dist/Magi.app and dist/Magi-macos.zip, ad-hoc signed (not notarized).

set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED="/private/tmp/magi-release-derived"
BUILD="/private/tmp/magi-release/Release"
DIST="$ROOT/dist"

cd "$ROOT"
xcodegen generate
xcodebuild \
  -project OutputLens.xcodeproj \
  -scheme OutputLens \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CONFIGURATION_BUILD_DIR="$BUILD" \
  CODE_SIGN_IDENTITY=- \
  build

mkdir -p "$DIST"
rm -rf "$DIST/Magi.app"
cp -R "$BUILD/OutputLens.app" "$DIST/Magi.app"
# Finder metadata and resource-fork attributes can survive the copy and make
# strict code-signature verification reject an otherwise valid app bundle.
xattr -cr "$DIST/Magi.app"

# Ad-hoc sign with a stable identifier requirement so a downloaded build keeps
# its Accessibility authorization across updates. This is not a Developer ID
# signature; users still clear Gatekeeper once (see README).
codesign \
  --force \
  --deep \
  --sign - \
  -r '=designated => identifier "com.azizemreayan.OutputLens"' \
  "$DIST/Magi.app"
codesign --verify --deep --strict "$DIST/Magi.app"

rm -f "$DIST/Magi-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST/Magi.app" "$DIST/Magi-macos.zip"

# Confirm the artifact users receive extracts with a valid signature too.
VERIFY_DIR="$(mktemp -d /private/tmp/magi-package-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$DIST/Magi-macos.zip" "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/Magi.app"

print "Built: $DIST/Magi-macos.zip"
