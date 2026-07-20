#!/bin/zsh

set -euo pipefail

OUTPUT_LENS_ROOT="${0:A:h}"
OUTPUT_LENS_DERIVED="/private/tmp/output-lens-derived"
OUTPUT_LENS_PRODUCTS="/private/tmp/output-lens-build/Debug"

cd "$OUTPUT_LENS_ROOT"
xcodegen generate
xcodebuild \
  -project OutputLens.xcodeproj \
  -scheme OutputLens \
  -configuration Debug \
  -derivedDataPath "$OUTPUT_LENS_DERIVED" \
  CONFIGURATION_BUILD_DIR="$OUTPUT_LENS_PRODUCTS" \
  CODE_SIGN_IDENTITY=- \
  build

OUTPUT_LENS_APP="$OUTPUT_LENS_PRODUCTS/OutputLens.app"
codesign --force --sign - "$OUTPUT_LENS_APP/Contents/MacOS/OutputLens.debug.dylib"
codesign --force --sign - "$OUTPUT_LENS_APP/Contents/MacOS/__preview.dylib"
codesign \
  --force \
  --sign - \
  -r '=designated => identifier "com.azizemreayan.OutputLens"' \
  "$OUTPUT_LENS_APP"
codesign --verify --deep --strict "$OUTPUT_LENS_APP"

print "Built: $OUTPUT_LENS_PRODUCTS/OutputLens.app"
