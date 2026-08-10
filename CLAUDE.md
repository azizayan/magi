# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Magi makes Codex and Claude desktop responses comfortably readable. It ships as **one app per platform** (see MIGRATION.md):

- **Magi for macOS** — the Swift/AppKit menu-bar app in `OutputLens/` (the Xcode target/module is still named `OutputLens`; the user-facing app is "Magi"). **Option-click** reads the clicked Codex (`com.openai.codex`) or Claude (`com.anthropic.claudefordesktop`) response through Accessibility. It also opens editable desktop inputs and provides a terminal editor whose Apply action temporarily pastes, never presses Return, and restores the previous clipboard.
- **Magi for Windows/Linux** — the Rust/egui app in `src/`: the cross-platform permission-free "Copy to Magi" clipboard reader.

The Option-click path requires the macOS Accessibility permission; rewriting it in Rust cannot remove that, which is why the Accessibility adapter lives only in the macOS app. The reader/renderer exists in both languages (each platform runs only one) — that duplication is expected.

plan.md holds the current implementation plan for response-boundary selection and the Semi-Code Editor. DESIGN.md is the approved product design.

## Commands

### Swift app (OutputLens)

Requires macOS 14+, Xcode, and XcodeGen. The Xcode project is generated from `project.yml` — edit that file (not the .xcodeproj) when adding source files, then regenerate with `xcodegen generate`.

```sh
./build.sh                   # xcodegen + debug build + re-sign; app in /private/tmp/output-lens-build/Debug
./scripts/package-macos.sh   # Local-only verified UNNOTARIZED ZIP + checksum
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
./scripts/build-macos-app.sh   # local ad-hoc Rust Magi.app bundle on macOS
```

## Swift app architecture

The Rust reader provides the permission-free clipboard path. It starts paused,
captures only through **Paste now** until Auto-update is explicitly enabled,
and provides a visible Clear action.

Flow for a modified click (default Option-click):

1. `AppController` owns the menu-bar item, a global `leftMouseDown` monitor, and the configurable trigger. On a matching click it asks `AccessibilityClient` for the target under the pointer.
2. `AccessibilityClient` resolves the AX element at the click point, verifies the app is supported, and extracts the response text. Selection/partitioning logic that decides *which* element is the response boundary is kept as pure, AX-free logic so it can be fixture-tested (see `ResponseHeuristics` / adapter types).
3. `ResponseBinding` combines Accessibility notifications with adaptive polling while the response streams, backs off while unchanged, and stops after sustained inactivity. Updates are accepted only when `isSafeUpdate` confirms the text is the same message; otherwise the panel shows **Connection paused** with the last confirmed text.
4. `ReaderPanelController` is a floating `NSPanel` attached to the source window's right side; it re-renders lightweight markdown (headings, lists, inline/fenced code) at a large font size. `appKitFrame(fromAccessibilityFrame:)` converts AX top-left screen coordinates to AppKit's flipped coordinates.
5. `SourceHighlightController` briefly outlines the selected source response.

Key invariants (from plan.md / DESIGN.md):

- The clicked location determines the response; never fall back to showing the whole conversation when the boundary is ambiguous — keep previous content and report the failure.
- Magi must never automatically submit, press Enter, or execute anything in the source app.
- Do not log content-derived fingerprints or raw Accessibility strings. Manual
  fixtures retain only structure, text lengths, and allowlisted control categories.

## Rust app architecture

`src/lib.rs` holds `ReaderState` (clipboard-driven content state), `src/markdown.rs` renders markdown into styled spans, `src/desktop.rs` wraps tray icon + global shortcut, and `src/main.rs` is the eframe app. Clipboard text never leaves the machine.
