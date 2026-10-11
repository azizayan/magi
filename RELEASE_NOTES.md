# Magi 0.1.0-alpha.1 for Codex

Magi is an open-source reading lens for Codex Desktop on macOS 14 or newer,
on Intel and Apple Silicon Macs.

Option-click an assistant response to open the whole answer in a larger
floating Reader panel, with adjustable text size and selectable text.

## Install from source

Clone the repository or download this tag's source archive, then follow the
Xcode and XcodeGen setup in README.md:

```sh
./build.sh
open /private/tmp/output-lens-build/Debug/OutputLens.app
```

Enable Magi in System Settings > Privacy & Security > Accessibility.
No Apple Developer membership, signing certificate, or notarization is needed
to build and run this source release locally.

## Alpha Scope

- Codex Desktop response reading is this alpha's focus.
- The response-boundary fix keeps paragraphs within one selected answer and
  preserves the selection while it streams.
- Extracted response text stays on your Mac.
- Prompt editing, other applications, terminals, and the Rust reader remain
  experimental and are outside the support promise for this release.

This is an early alpha. Live response capture can vary with Codex versions;
report incomplete captures through GitHub Issues. The latest boundary fix has
automated regression coverage, but its live Codex smoke test remains pending.

This release contains source only. Local `UNNOTARIZED` archives are not public
download assets. Magi is MIT-licensed and is not affiliated with OpenAI.
