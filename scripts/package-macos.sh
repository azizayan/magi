#!/bin/zsh

# Build a distributable macOS release of the Magi app (the Swift build that
# offers both permission-free clipboard capture and Option-click reading).
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

print "Built: $DIST/Magi-macos.zip"
