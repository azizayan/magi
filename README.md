# Magi

Magi makes Codex and Claude desktop output comfortably readable: it lifts one
model response into a large, high-contrast reading panel without changing the
source application.

There is one Magi product with a native app per platform:

- **Magi for macOS** (Swift/AppKit) — a menu-bar app activated only by
  **Option-click**, which reads the exact response through Accessibility.
- **Magi for Windows and Linux** (Rust/egui) — the cross-platform **Copy to
  Magi** clipboard reader. No Accessibility permission required.

Extracted text always stays on the local machine.

## Magi for macOS

**Option-click (needs Accessibility).** Option-click a response to open exactly
the clicked assistant message in **Reader** mode:

- Per-app adapters (Codex, Claude) treat message-action rows as message
  boundaries and partition the conversation by them; there is no
  whole-conversation fallback. An unidentifiable boundary keeps the previous
  content and reports the failure instead of showing the whole chat.
- Streaming stays bound to the same message (verified by section index and text
  fingerprint); it pauses rather than switching messages.
- An optional dimmed **prompt** header (off by default) shows the message that
  produced the response.
- Option-click an editable input to open **Editor** mode: a large monospaced
  draft whose **Apply to Input** writes back through Accessibility and never
  submits or runs anything. Drafts survive a lost source element.
- Option-click a supported terminal—including Terminal, iTerm2, Warp, Ghostty,
  Kitty, Alacritty, WezTerm, Hyper, Rio, Wave, and Tabby—to open an empty
  **Semi-Code Editor**. This works for Codex CLI, Claude Code, and ordinary
  shell commands because Magi integrates with the terminal host.
- Integrated terminals in VS Code, Cursor, VSCodium, Windsurf, and Antigravity
  are recognized by their terminal Accessibility surface; other IDE areas are
  deliberately left alone.
- Press **Option-M** while any terminal pane is focused to open the Semi-Code
  Editor without relying on the host's Accessibility labels. This universal
  fallback works with unknown terminal apps, integrated IDE terminals, and any
  CLI running inside them.
  **Apply** replaces the focused terminal's current input with the draft; Magi
  never presses Enter or executes the command. Applying an empty draft clears
  the terminal input.
- Links in a rendered response are clickable.

### Build and run

Requirements: macOS 14+, Xcode, and XcodeGen. The Xcode project is generated
from `project.yml`; edit that (not the `.xcodeproj`) and run `xcodegen generate`.

```sh
./build.sh                    # debug build at /private/tmp/output-lens-build/Debug
./scripts/package-macos.sh    # distributable dist/Magi.app + dist/Magi-macos.zip
```

Tests:

```sh
xcodebuild -project OutputLens.xcodeproj -scheme OutputLens \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/output-lens-derived \
  CODE_SIGNING_ALLOWED=NO test
```

For Option-click, the first launch opens **System Settings → Privacy & Security
→ Accessibility**; enable Magi and return to Codex or Claude.

## Magi for Windows and Linux

The Rust app is the cross-platform **Copy to Magi** reader: start it, then use
the Copy button on a complete response. The always-on-top reader updates from
the clipboard with no Accessibility access. It supports selectable text,
persistent font size, pausing automatic updates, manual **Paste now** capture,
and a configurable global show/hide shortcut (default **Option-M**). Closing the
window hides it; the menu-bar icon can show/hide, pause, or quit.

```sh
cargo run       # run the reader
cargo test      # unit tests
```

The Rust reader also builds on macOS (`./scripts/build-macos-app.sh`) if you
prefer the permission-free reader on its own.

While automatic updates are enabled, any copied text replaces the reader; pause
updates before copying sensitive text.

## Installing a downloaded macOS build

Release builds are ad-hoc signed, not notarized with an Apple Developer ID, so
macOS Gatekeeper shows a warning the first time. To open a downloaded `Magi.app`:

- Right-click the app and choose **Open**, then confirm; or
- clear the quarantine flag once: `xattr -dr com.apple.quarantine /path/to/Magi.app`.

This is expected for an unsigned build and only needs to be done once.

## Documentation

- [DESIGN.md](DESIGN.md) — product and connection design.
- [plan.md](plan.md) — response-selection and Semi-Code Editor implementation plan.
- [MIGRATION.md](MIGRATION.md) — the Rust/Swift split and how the apps relate.
- [PUBLISHING.md](PUBLISHING.md) — release steps.

## License

Magi is released under the [MIT License](LICENSE).
