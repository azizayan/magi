# Magi 0.1.0 Beta

Magi makes Codex and Claude output easier to read and gives terminal prompts a
large, focused editing surface.

## macOS

Download `Magi-macos.zip`, extract it, then right-click **Magi** and choose
**Open**. This beta is ad-hoc signed and is not notarized, so macOS will show a
Gatekeeper warning on first launch.

- Option-click a Codex or Claude response to show that complete response in a
  large, high-contrast Reader panel.
- Streaming stays bound to the selected response instead of switching to the
  whole conversation.
- Option-click a supported input to open the Semi-Code Editor.
- Terminal, iTerm2, Warp, Ghostty, Kitty, Alacritty, WezTerm, Hyper, Rio, Wave,
  Tabby, and common IDE terminals are supported.
- Focus any terminal and press **Option-M** for the universal terminal-editor
  fallback.
- Applying a terminal draft copies it and returns focus to the terminal. Magi
  never pastes, submits, or executes the command automatically.

Option-click and source write-back require macOS Accessibility permission. All
captured text remains local on the Mac.

## Windows and Linux

The Rust clipboard reader is available as a source build in this beta.
Repository collaborators can install the Rust toolchain, clone the repository,
and run `cargo run --release`.

Packaged Windows and Linux binaries are planned for a later release.
