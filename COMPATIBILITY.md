# Magi compatibility matrix

Run this matrix on the exact release candidate. Record the app version, macOS
version, date, and pass/fail notes in the release issue. A unit-test pass is not
a substitute for these live Accessibility and event-consumption checks.

## Desktop response and input

| Host | Whole early response | Whole long response | Streaming update | Input edit/apply | Empty draft clears |
|---|---:|---:|---:|---:|---:|
| Codex desktop | ☐ | ☐ | ☐ | ☐ | ☐ |
| Claude desktop | ☐ | ☐ | ☐ | ☐ | ☐ |

## Terminal and CLI

For every row, exercise a normal shell prompt, Codex CLI, and Claude Code when
available. Apply must replace the current input without submitting it, then
restore the previous clipboard. Switching apps before Apply must fail closed.

| Host | Option-click opens Editor | Option-M opens Editor | Replace works | Empty clears | No Return | Clipboard restored |
|---|---:|---:|---:|---:|---:|---:|
| Terminal.app | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| iTerm2 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Warp | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Ghostty | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| VS Code integrated terminal | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Cursor integrated terminal | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

Add a row for every newly reported terminal host before marking it supported.

## Automated live host

`./scripts/test-macos-integration.sh` launches `MagiIntegrationHost.app` and
checks real AX direct write-back, focus transfer, synthetic replacement, and
the invariant that Return is never sent. It requires Accessibility permission
for the Xcode test host and intentionally skips from ordinary CI runs.
