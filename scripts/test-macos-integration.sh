#!/bin/zsh

set -euo pipefail

MAGI_ROOT="${0:A:h:h}"
MAGI_DERIVED="/private/tmp/magi-integration-derived"

cd "$MAGI_ROOT"
xcodegen generate
xcodebuild \
  -project OutputLens.xcodeproj \
  -scheme OutputLensIntegration \
  -destination 'platform=macOS' \
  -derivedDataPath "$MAGI_DERIVED" \
  test -only-testing:OutputLensTests/AccessibilityIntegrationTests
