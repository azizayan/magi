# Magi Rust Migration

## Decision

Magi ships as a native enhanced app on macOS and a cross-platform clipboard
reader for Windows and Linux:

- **Magi for macOS** is the Swift/AppKit app: enhanced **Option-click** Reader
  mode and the Semi-Code Editor, both using Accessibility.
- **Magi for Windows and Linux** is the Rust/egui app: the cross-platform
  **Copy to Magi** clipboard reader.

The Rust clipboard reader can also be built on macOS, but it is not bundled
with the Swift `Magi-macos.zip` release artifact.

The two capture *methods* remain intentionally different, and that difference is
why the codebases stay split by platform rather than merged into one language:

- **Copy to Magi** does not inspect another application's interface, so it needs
  no Accessibility permission. It is implemented in Rust with `arboard`.
- **Option-click** reads another application's element beneath a global click,
  which requires macOS Accessibility APIs. Rewriting that adapter in Rust cannot
  remove the operating-system permission, so it lives only in the macOS app.

Screen capture and OCR are not a permission-free substitute: they are less reliable and require screen-capture authorization on macOS.

## Architecture

```text
Codex / Claude Copy action
            |
      system clipboard
            |
  Rust clipboard adapter (arboard)
            |
     ReaderState core
            |
  Rust reader window (eframe/egui)
```

The current Swift application remains isolated from the Rust app. This avoids a risky rewrite and keeps the working Option-click mode available while migration continues.

## Migration stages

1. **Cross-platform foundation — implemented**
   - Rust application builds as `magi`.
   - New copied text replaces the reader content.
   - Startup clipboard content is not read or shown automatically.
   - Automatic updates are opt-in; `Paste now` and `Clear` remain available.
   - The reader is resizable, stays above normal windows, supports text selection, and remembers text size.
   - Copying a selection from the reader does not replace the displayed response.

2. **Reader parity — implemented**
   - Markdown headings, lists, inline code, and fenced code blocks are rendered with readable typography.
   - Prose uses an installed bold system font on macOS, Windows, and Linux, with a bundled fallback.
   - Rendered text remains selectable and code indentation is preserved.

3. **Platform packaging and validation**
   - Local ad-hoc packaging produces an explicitly unnotarized ZIP and checksum;
     public Swift binaries require Developer ID signing and notarization.
   - Menu-bar lifecycle, close-to-hide behavior, and a configurable global show/hide shortcut are implemented.
   - Local tests, strict linting, and a macOS UI smoke test pass.
   - A macOS Swift and macOS/Windows/Linux Rust CI matrix, RustSec audit,
     dependency updates, secret scan, and public-repository CodeQL are configured.
   - Signed installers and physical Windows/Linux smoke tests remain release work, not part of the source migration.

4. **Optional native adapters**
   - Port the macOS Accessibility adapter only for users who enable enhanced Option-click mode.
   - The macOS adapter includes a Semi-Code Editor with direct write-back for
     settable Codex/Claude inputs and a transient paste handoff for terminals.
     It restores the previous clipboard and never submits prompts or executes commands.
   - Investigate Windows UI Automation and Linux AT-SPI separately; each has platform-specific permissions and application-tree differences.

## Security and privacy boundary

**Auto-update** starts disabled. While the user explicitly enables it, Magi reads
text clipboard changes locally and never sends them over the network. Disable it
before copying unrelated or sensitive text, and use Clear when finished.

## Verification

```sh
cargo test
cargo build
cargo run
```

Manual smoke test:

1. Start Magi; confirm existing clipboard content is not displayed.
2. Copy a complete response; confirm it appears without granting Accessibility access.
3. Select and copy a portion of the text from Magi.
4. Pause Auto-update, copy unrelated text, and confirm the reader does not change.
5. Click **Paste now** and confirm the reader updates.
