# Magi Rust Migration

## Decision

Magi will use a shared Rust desktop application for the permission-free workflow and retain the existing native Swift application until the enhanced macOS workflow reaches feature parity.

The two workflows are intentionally different:

- **Copy to Magi** is the cross-platform default. Copying a complete response in Codex or Claude replaces the reader content. It does not inspect another application's interface and therefore does not need macOS Accessibility permission.
- **Option-click** is an enhanced macOS workflow. Reading another application's element beneath a global click requires macOS Accessibility APIs. Rewriting that adapter in Rust cannot remove the operating-system permission.

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
   - Startup clipboard content is not shown automatically.
   - Automatic updates can be paused; `Paste now` remains available.
   - The reader is resizable, stays above normal windows, supports text selection, and remembers text size.
   - Copying a selection from the reader does not replace the displayed response.

2. **Reader parity — implemented**
   - Markdown headings, lists, inline code, and fenced code blocks are rendered with readable typography.
   - Prose uses an installed bold system font on macOS, Windows, and Linux, with a bundled fallback.
   - Rendered text remains selectable and code indentation is preserved.

3. **Platform packaging and validation — implemented for development**
   - A local unsigned macOS `.app` packaging script is implemented.
   - CI compiles, tests, and lints the Rust app on macOS, Windows, and Linux.
   - Signed installers and physical Windows/Linux smoke tests remain release work, not part of the source migration.

4. **Optional native adapters**
   - Port the macOS Accessibility adapter only for users who enable enhanced Option-click mode.
   - Investigate Windows UI Automation and Linux AT-SPI separately; each has platform-specific permissions and application-tree differences.

## Security and privacy boundary

While **Auto-update** is enabled, Magi reads text clipboard changes locally. It does not send clipboard content over the network. Pause Auto-update before copying unrelated or sensitive text. A future source-app filter must be implemented separately for each operating system and should not be claimed as cross-platform until it is validated on all three.

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
