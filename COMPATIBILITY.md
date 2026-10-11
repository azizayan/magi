# Magi compatibility matrix

Run this matrix on the exact release candidate. Record the app version, macOS
version, date, and pass/fail notes in the release issue. A unit-test pass is not
a substitute for these live Accessibility and event-consumption checks.

## Source Alpha 0.1.0-alpha.1

Validated on October 11, 2026:

- Universal macOS Release build and archive signature/checksum checks passed.
  The local unnotarized archive is not a public release asset.
- The direct XCTest runner executed 93 Swift tests with no failures; the one
  permission-dependent live Accessibility test was skipped.
- Swift static analysis, Rust formatting, 10 Rust tests, Clippy with warnings
  denied, and the RustSec dependency audit passed.
- Git history secret scan passed before publication.

Codex Desktop response reading is the alpha's intended workflow. Live Codex
Option-click validation of the latest boundary fix remains pending; the matrix
below is intentionally unchecked. Other integrations remain experimental.

## Desktop response and input

| Host | Whole early response | Whole long response | Streaming update | Input edit/apply | Empty draft clears |
|---|---:|---:|---:|---:|---:|
| Codex desktop | ☐ | ☐ | ☐ | ☐ | ☐ |
| Claude desktop | ☐ | ☐ | ☐ | ☐ | ☐ |

## Terminal and CLI

For every row, exercise a normal shell prompt, Codex CLI, and Claude Code when
available. Apply must replace the current input without submitting it, then
restore the previous clipboard. Switching apps before Apply must fail closed.

| Host | Option-click reads output | Exact CLI hook | Generic command | Option-M editor | Replace works | Empty clears | No Return | Clipboard restored |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Terminal.app | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| iTerm2 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Warp | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Ghostty | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| VS Code integrated terminal | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Cursor integrated terminal | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

Add a row for every newly reported terminal host before marking it supported.

## Automated live host

`./scripts/test-macos-integration.sh` launches `MagiIntegrationHost.app` and
checks real AX direct write-back, focus transfer, synthetic replacement, and
the invariant that Return is never sent. It requires Accessibility permission
for the Xcode test host and intentionally skips from ordinary CI runs.
