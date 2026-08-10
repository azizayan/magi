# Publishing Magi

Public source distribution is allowed now. A public macOS binary is allowed
only after Developer ID signing and Apple notarization succeed. The local
ad-hoc artifact is deliberately named `Magi-macos-UNNOTARIZED.zip` and must
never be attached to a public release.

## Required automated gates

Run the same checks as `.github/workflows/ci.yml`:

```sh
cargo fmt --all -- --check
cargo test --locked --all-targets --all-features
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo audit --deny warnings

xcodegen generate
xcodebuild -project OutputLens.xcodeproj -scheme OutputLens \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/magi-tests \
  CODE_SIGNING_ALLOWED=NO test
xcodebuild -project OutputLens.xcodeproj -scheme OutputLens \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/magi-analyze \
  CODE_SIGNING_ALLOWED=NO analyze
```

The normal Swift suite builds the internal Accessibility host and skips its
permission-dependent live test. On a development Mac with Accessibility access,
also run:

```sh
./scripts/test-macos-integration.sh
```

Complete and record [COMPATIBILITY.md](COMPATIBILITY.md) against the release
candidate.

## Source-only release (no Apple Developer account)

Publish the tagged source through GitHub. Do not attach the output of the
default packaging command. Users build the Swift app with `./build.sh` or run
the Rust reader with `cargo run --locked`.

## Local package verification

```sh
./scripts/package-macos.sh
shasum -a 256 -c dist/Magi-macos-UNNOTARIZED.zip.sha256
```

This path verifies the app signature before and after ZIP extraction and emits
a checksum, but the signature is ad-hoc and has no publisher authentication.

## Notarized public macOS binary

Store notarization credentials in the keychain once:

```sh
xcrun notarytool store-credentials magi-notary \
  --apple-id "YOUR_APPLE_ID" --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

Build the public artifact:

```sh
MAGI_PUBLIC_RELEASE=1 \
MAGI_SIGNING_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
MAGI_NOTARY_PROFILE=magi-notary \
./scripts/package-macos.sh
```

The command fails closed when either release credential is absent. It enables
the hardened runtime, signs with a timestamp, submits to Apple, waits for
acceptance, staples and validates the ticket, checks Gatekeeper after extracting
the final ZIP, and writes `dist/Magi-macos.zip.sha256`.

Before uploading:

```sh
shasum -a 256 -c dist/Magi-macos.zip.sha256
VERIFY_DIR="$(mktemp -d /private/tmp/magi-release-check.XXXXXX)"
ditto -x -k dist/Magi-macos.zip "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/Magi.app"
spctl --assess --type execute --verbose "$VERIFY_DIR/Magi.app"
```

Publish only the verified ZIP and checksum. The packaging script deletes its
unpacked staging bundle because Finder metadata can change it after verification.

## Manual smoke test

1. Option-click early, middle, late, and very long Codex and Claude responses.
2. Confirm the whole clicked response appears and no adjacent turn is included.
3. Option-click desktop inputs and apply empty and non-empty drafts.
4. Use Option-M in each terminal host in the compatibility matrix.
5. Confirm Apply replaces input, never presses Return, and restores the prior
   multi-item clipboard.
6. Switch to another app before Apply and confirm Magi refuses to send keys.
7. Confirm only HTTP(S) links open; `file:` and custom schemes remain inert.
8. Save a diagnostic fixture and search it for source prompts, paths, tokens,
   labels, identifiers, and action help text; none may be present.
