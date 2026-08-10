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
- Streaming stays bound to the same message, refreshes adaptively, and wakes
  from Accessibility notifications; it pauses rather than switching messages.
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
- Press **Option-M** while a known terminal app or Accessibility-marked terminal
  pane is focused to open the Semi-Code Editor. Ordinary editors, browsers, and
  unmarked IDE controls are rejected so replacement keys cannot target them.
  **Apply** replaces the focused terminal's current input with the draft; Magi
  never presses Enter or executes the command. Applying an empty draft clears
  the terminal input.
- `http` and `https` links in a rendered response are clickable; local files and
  application URL schemes stay inert.

### Build and run

Requirements: macOS 14+, Xcode, and XcodeGen. The Xcode project is generated
from `project.yml`; edit that (not the `.xcodeproj`) and run `xcodegen generate`.

```sh
./build.sh                    # debug build at /private/tmp/output-lens-build/Debug
./scripts/package-macos.sh    # local-only dist/Magi-macos-UNNOTARIZED.zip + SHA-256
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

The Rust app is the cross-platform **Copy to Magi** reader. It starts paused and
does not read clipboard contents at launch: copy a complete response and choose
**Paste now**. Selectable text, persistent font size, a visible **Clear** action,
opt-in automatic updates, and a configurable global show/hide shortcut (default
**Option-M**) are included. Closing hides the window. macOS and Windows also
provide a tray/menu-bar icon; Linux omits it to avoid the unmaintained GTK3
dependency graph and keeps the window plus global shortcut.

```sh
cargo run       # run the reader
cargo test      # unit tests
```

The Rust reader also builds on macOS (`./scripts/build-macos-app.sh`) if you
prefer the permission-free reader on its own.

Auto-update is deliberately opt-in. While enabled, every copied text value can
replace the reader; turn it off before copying sensitive material and use
**Clear** when finished.

## macOS distribution security

The default package command creates an explicitly named local, ad-hoc artifact;
it is not a public download. Until a Developer ID is configured, public testers
should build Magi from this repository. Public binary releases are required to
use hardened-runtime Developer ID signing, Apple notarization and stapling, and
the generated SHA-256 checksum. See [PUBLISHING.md](PUBLISHING.md).

## Documentation

- [DESIGN.md](DESIGN.md) — product and connection design.
- [plan.md](plan.md) — response-selection and Semi-Code Editor implementation plan.
- [MIGRATION.md](MIGRATION.md) — the Rust/Swift split and how the apps relate.
- [PUBLISHING.md](PUBLISHING.md) — release steps.
- [COMPATIBILITY.md](COMPATIBILITY.md) — live Accessibility and terminal smoke matrix.

## License

Magi is released under the [MIT License](LICENSE).
