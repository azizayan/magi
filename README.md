# Magi / Output Lens

Magi is migrating Output Lens into a cross-platform Rust reader for Codex and Claude output. The working native macOS prototype remains available during the migration.

## Rust cross-platform app

The Rust app uses a permission-free **Copy to Magi** workflow: start Magi, then use the Copy button on a complete Codex or Claude response. The always-on-top reader updates from the clipboard without macOS Accessibility access.

```sh
cargo run
```

On macOS, build a normal app bundle with:

```sh
./scripts/build-macos-app.sh
open target/debug/Magi.app
```

The reader supports selectable text, persistent font size, pausing automatic clipboard updates, and manual **Paste now** capture. Clipboard text stays on the computer. While automatic updates are enabled, unrelated text copies will also replace the reader; pause updates before copying sensitive text.

Run Rust tests with `cargo test`. See [MIGRATION.md](MIGRATION.md) for the architecture, permission boundary, migration stages, and manual validation checklist.

Every push is compiled, tested, and linted on macOS, Windows, and Linux in GitHub Actions.

## Native macOS prototype

The Swift prototype provides the enhanced Option-click workflow. It still needs macOS Accessibility permission because it reads response elements from another application; implementing the adapter in Rust cannot remove that operating-system requirement.

### Current prototype

- Targets Codex (`com.openai.codex`) and Claude (`com.anthropic.claudefordesktop`).
- Option-click a response to open the whole response.
- Uses response-level Accessibility controls to avoid stopping at an inner list or code block.
- Keeps the panel bound to that response while its text streams.
- Replaces the content when another response is selected.
- Moves and resizes with the source window.
- Hides when the source application is not active.
- Offers alternative modifier-click triggers from its menu-bar icon.
- Offers persistent smaller/larger text controls in the reading panel.
- Briefly outlines the selected source response so the active connection is visible.
- Styles bullets, headings, inline code, and fenced code blocks for easier scanning.
- Closing the panel ends its active streaming connection.
- Keeps all extracted text on the Mac.

### Build and run

Requirements: macOS 14 or newer, Xcode, and XcodeGen.

```sh
./build.sh
open "/private/tmp/output-lens-build/Debug/OutputLens.app"
```

The first launch opens **System Settings → Privacy & Security → Accessibility**. Enable Output Lens, return to Codex or Claude, and Option-click directly on response text.

The development build embeds a stable bundle-identifier requirement after Xcode's ad-hoc signing step. This keeps macOS Accessibility authorization valid across local rebuilds. A distributed production build should use an Apple Developer certificate instead.

### Tests

```sh
xcodebuild \
  -project OutputLens.xcodeproj \
  -scheme OutputLens \
  -destination 'platform=macOS' \
  -derivedDataPath "/private/tmp/output-lens-derived" \
  CODE_SIGNING_ALLOWED=NO \
  test
```

### Prototype limitation

Response-container selection is based on the applications' Accessibility trees. Claude's current desktop build exposes the required response containers. Codex still needs live validation on the current build. If either app changes its Accessibility hierarchy, its selection adapter may need an update.

See [DESIGN.md](DESIGN.md) for the approved product and connection design.
