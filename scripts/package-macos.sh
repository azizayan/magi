#!/bin/zsh

# Build a distributable macOS release of the Swift Magi app, which provides
# Option-click Reader mode and the Semi-Code Editor.
# Local mode produces an explicitly named unnotarized archive. Public-release
# mode refuses to run without Developer ID signing and notarization settings.

set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED="/private/tmp/magi-release-derived"
BUILD="/private/tmp/magi-release/Release"
DIST="$ROOT/dist"
PUBLIC_RELEASE="${MAGI_PUBLIC_RELEASE:-0}"
SIGNING_IDENTITY="${MAGI_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${MAGI_NOTARY_PROFILE:-}"

if [[ "$PUBLIC_RELEASE" == "1" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" || -z "$NOTARY_PROFILE" ]]; then
    print -u2 "Public releases require MAGI_SIGNING_IDENTITY and MAGI_NOTARY_PROFILE."
    exit 1
  fi
  ARCHIVE="$DIST/Magi-macos.zip"
else
  SIGNING_IDENTITY="-"
  ARCHIVE="$DIST/Magi-macos-UNNOTARIZED.zip"
fi

cd "$ROOT"
xcodegen generate
xcodebuild \
  -project OutputLens.xcodeproj \
  -scheme OutputLens \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CONFIGURATION_BUILD_DIR="$BUILD" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  build

mkdir -p "$DIST"
rm -rf "$DIST/Magi.app"
cp -R "$BUILD/OutputLens.app" "$DIST/Magi.app"
# Finder metadata and resource-fork attributes can survive the copy and make
# strict code-signature verification reject an otherwise valid app bundle.
xattr -cr "$DIST/Magi.app"

if [[ "$PUBLIC_RELEASE" == "1" ]]; then
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$DIST/Magi.app"
else
  # A stable ad-hoc requirement keeps local Accessibility authorization across
  # rebuilds. This artifact is intentionally blocked from the public path.
  codesign --force --deep --sign - \
    -r '=designated => identifier "com.azizemreayan.OutputLens"' \
    "$DIST/Magi.app"
fi
codesign --verify --deep --strict "$DIST/Magi.app"

rm -f "$DIST/Magi-macos.zip" "$DIST/Magi-macos-UNNOTARIZED.zip" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$DIST/Magi.app" "$ARCHIVE"

if [[ "$PUBLIC_RELEASE" == "1" ]]; then
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DIST/Magi.app"
  xcrun stapler validate "$DIST/Magi.app"
  rm -f "$ARCHIVE"
  ditto -c -k --sequesterRsrc --keepParent "$DIST/Magi.app" "$ARCHIVE"
fi

# Confirm the artifact users receive extracts with a valid signature too.
VERIFY_DIR="$(mktemp -d /private/tmp/magi-package-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/Magi.app"
if [[ "$PUBLIC_RELEASE" == "1" ]]; then
  spctl --assess --type execute --verbose "$VERIFY_DIR/Magi.app"
fi

shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
# The unpacked bundle is only a staging product. Finder/file-provider metadata
# can mutate it after verification, so keep only the immutable verified archive.
rm -rf "$DIST/Magi.app"
if [[ "$PUBLIC_RELEASE" != "1" ]]; then
  print -u2 "WARNING: local archive is ad-hoc signed and not notarized; do not attach it to a public release."
fi
print "Built: $ARCHIVE"
print "Checksum: $ARCHIVE.sha256"
