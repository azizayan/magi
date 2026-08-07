# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Magi makes Codex and Claude desktop responses comfortably readable. It ships as **one app per platform** (see MIGRATION.md):

- **Magi for macOS** — the Swift/AppKit menu-bar app in `OutputLens/` (the Xcode target/module is still named `OutputLens`; the user-facing app is "Magi"). It has **both** capture modes: permission-free **Copy to Magi** (clipboard, `ClipboardReader`) and enhanced **Option-click** (Accessibility) that reads the clicked response out of Codex (`com.openai.codex`) or Claude (`com.anthropic.claudefordesktop`). Option-click also opens editable Codex/Claude inputs directly and provides an explicit-paste editor for Terminal/iTerm2.
- **Magi for Windows/Linux** — the Rust/egui app in `src/`: the cross-platform permission-free "Copy to Magi" clipboard reader.

The Option-click path requires the macOS Accessibility permission; rewriting it in Rust cannot remove that, which is why the Accessibility adapter lives only in the macOS app. The reader/renderer exists in both languages (each platform runs only one) — that duplication is expected.

plan.md holds the current implementation plan for response-boundary selection and the Semi-Code Editor. DESIGN.md is the approved product design.

## Commands

### Swift app (OutputLens)

Requires macOS 14+, Xcode, and XcodeGen. The Xcode project is generated from `project.yml` — edit that file (not the .xcodeproj) when adding source files, then regenerate with `xcodegen generate`.

```sh
./build.sh                   # xcodegen + debug build + re-sign; app in /private/tmp/output-lens-build/Debug
./scripts/package-macos.sh   # Release build → distributable dist/Magi.app + dist/Magi-macos.zip
```

New source files require `xcodegen generate` before `xcodebuild` picks them up; `build.sh` and `package-macos.sh` run it for you.

Tests:

```sh
xcodebuild \
  -project OutputLens.xcodeproj \
  -scheme OutputLens \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/output-lens-derived \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Run a single test with `-only-testing:OutputLensTests/<ClassName>/<testName>` appended.

build.sh embeds a stable bundle-identifier code-signing requirement after Xcode's ad-hoc signing so the macOS Accessibility authorization survives local rebuilds.

### Rust app

```sh
cargo run                      # run the reader
cargo test                     # unit tests
./scripts/build-macos-app.sh   # unsigned Magi.app bundle on macOS
```

## Swift app architecture

`ClipboardReader` provides the permission-free path: it polls `NSPasteboard` change counts and surfaces newly copied text to `AppController`, which shows it via `ReaderPanelController.showClipboardText` (no window binding). `AppController` guards against re-showing a selection the user copied out of the reader. Pre-existing clipboard content is never shown automatically.

Flow for a modified click (default Option-click):

1. `AppController` owns the menu-bar item, a global `leftMouseDown` monitor, and the configurable trigger. On a matching click it asks `AccessibilityClient` for the target under the pointer.
2. `AccessibilityClient` resolves the AX element at the click point, verifies the app is supported, and extracts the response text. Selection/partitioning logic that decides *which* element is the response boundary is kept as pure, AX-free logic so it can be fixture-tested (see `ResponseHeuristics` / adapter types).
3. `ResponseBinding` polls the bound element (0.25 s timer) while the response streams. Updates are accepted only when `isSafeUpdate` confirms the text is the same message (prefix/fingerprint match); otherwise the panel shows **Connection paused** with the last confirmed text. It must never silently switch to a neighboring response or expand to the whole conversation.
4. `ReaderPanelController` is a floating `NSPanel` attached to the source window's right side; it re-renders lightweight markdown (headings, lists, inline/fenced code) at a large font size. `appKitFrame(fromAccessibilityFrame:)` converts AX top-left screen coordinates to AppKit's flipped coordinates.
5. `SourceHighlightController` briefly outlines the selected source response.

Key invariants (from plan.md / DESIGN.md):

- The clicked location determines the response; never fall back to showing the whole conversation when the boundary is ambiguous — keep previous content and report the failure.
- Magi must never automatically submit, press Enter, or execute anything in the source app.
- Do not log full conversation text; diagnostics use text lengths and fingerprints.

## Rust app architecture

`src/lib.rs` holds `ReaderState` (clipboard-driven content state), `src/markdown.rs` renders markdown into styled spans, `src/desktop.rs` wraps tray icon + global shortcut, and `src/main.rs` is the eframe app. Clipboard text never leaves the machine.
