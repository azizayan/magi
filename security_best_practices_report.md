# Magi Security and Code Quality Remediation Report

Original audit: 2026-08-10  
Remediation completed: 2026-08-10

## Executive summary

All findings from the original audit have been remediated in code, tests,
automation, or a fail-closed release policy. No critical remote-code-execution
path was found. Magi still has an intentionally powerful macOS Accessibility
boundary, but diagnostics no longer export private AX strings, terminal events
are restricted and revalidated, temporary clipboard content is restored, and
public macOS binaries are blocked unless Developer ID signing and notarization
succeed.

The available security skill contains language packs for Python,
JavaScript/TypeScript, and Go, but not Swift or Rust. These remediations were
therefore validated against macOS Accessibility/AppKit behavior, RustSec, and
general desktop security criteria.

## Remediated security findings

### MAGI-SEC-001 — Resolved: diagnostic fixture confidentiality

- `SnapshotRedaction` removes raw text, labels, identifiers, and unrecognized
  action/help strings; only text length, structure, and allowlisted response
  control categories survive ([AccessibilitySnapshot.swift](OutputLens/AccessibilitySnapshot.swift), lines 118–174).
- Structural logging performs its own redaction, so callers cannot accidentally
  pass a raw snapshot ([AccessibilitySnapshot.swift](OutputLens/AccessibilitySnapshot.swift), lines 152–156).
- Stable content-derived hashes were removed from fixtures and logs.
- Debug builds no longer auto-write every click to Downloads; export is an
  explicit menu action ([AccessibilityClient.swift](OutputLens/AccessibilityClient.swift), lines 159–162).
- Regression tests encode secrets in text, description, identifier, and action
  fields and prove none survive JSON or structural logging
  ([AccessibilitySnapshotTests.swift](OutputLensTests/AccessibilitySnapshotTests.swift)).
- The legacy auto-captured `~/Downloads/magi-last-click.json` found during the
  audit was moved to Trash as `magi-last-click.pre-security-fix.json`.

### MAGI-SEC-002 — Resolved: RustSec dependency graph

- `quick-xml` is updated to 0.41.0 and `event-listener` to 5.4.2 in `Cargo.lock`.
- The Linux tray dependency was removed because its backend required the
  unmaintained GTK3/glib graph. macOS and Windows retain the tray; Linux keeps
  its reader window and global shortcut ([Cargo.toml](Cargo.toml), lines 21–27;
  [desktop.rs](src/desktop.rs)).
- `cargo audit --deny warnings` now exits successfully with no vulnerabilities,
  unsound crates, yanked crates, or unmaintained warnings.

### MAGI-SEC-003 — Resolved: terminal clipboard exposure

- `PasteboardTransaction` snapshots every prior item and type, marks the draft
  transient, and restores the prior clipboard after paste
  ([EditorBinding.swift](OutputLens/EditorBinding.swift), lines 35–80).
- Restoration occurs only while Magi's private random marker remains, so a new
  user/application copy is never overwritten.
- Failed synthetic paste restores immediately and preserves the draft in Magi
  ([AppController.swift](OutputLens/AppController.swift), lines 236–265).
- Tests cover multi-item/multi-type restoration and concurrent clipboard
  changes ([EditorBindingTests.swift](OutputLensTests/EditorBindingTests.swift)).

### MAGI-SEC-004 — Resolved: model-controlled URL schemes

- Rendering and click handling both call `safeWebURL`, which permits only HTTP
  or HTTPS URLs with a host ([ReaderPanelController.swift](OutputLens/ReaderPanelController.swift),
  lines 153–159 and 551–559).
- Tests prove `file:`, `javascript:`, custom application schemes, FTP, relative,
  and hostless URLs remain non-interactive.

### MAGI-SEC-005 — Resolved: terminal target confusion

- Option-M accepts only recognized terminal hosts or focused AX ancestry with a
  terminal marker; ordinary apps and unmarked IDE controls fail closed
  ([AccessibilityClient.swift](OutputLens/AccessibilityClient.swift), lines 200–237).
- Editor sources bind PID, bundle identifier, element, and window.
- Immediately before key posting, Magi revalidates process identity, frontmost
  application, element/window liveness, and focused source window; the event
  function repeats validation ([AccessibilityClient.swift](OutputLens/AccessibilityClient.swift),
  lines 629–671).
- Unit tests cover target eligibility, and the live host verifies actual focus
  transfer and event consumption without Return.

### MAGI-SEC-006 — Resolved: broad Rust clipboard capture

- The Rust reader starts paused and does not read clipboard content at launch
  ([lib.rs](src/lib.rs), lines 10–16; [main.rs](src/main.rs), lines 56–72).
- Paste now is the explicit one-shot default; Auto-update is opt-in and its UI
  states that it observes all copied text. Clear immediately discards content.
- Tests cover the paused default, explicit capture, pause behavior, and clearing.

### MAGI-SEC-007 — Resolved by fail-closed release policy

- The default package is explicitly named `Magi-macos-UNNOTARIZED.zip`, emits a
  SHA-256 checksum, warns against public distribution, verifies before and after
  extraction, and deletes the mutable unpacked staging app
  ([package-macos.sh](scripts/package-macos.sh), lines 14–88).
- Public mode refuses to build without both a Developer ID identity and an Apple
  notary profile. It requires hardened-runtime signing, timestamping,
  notarization, stapling, Gatekeeper assessment, and a checksum.
- Until those credentials exist, the documented public path is source-only;
  quarantine bypass instructions and ad-hoc binary release notes were removed
  ([PUBLISHING.md](PUBLISHING.md), lines 1–89).

## Remediated code quality and release findings

### MAGI-QUAL-001 — Resolved: security automation

- CI now runs Swift Analyze/tests/package validation; Rust fmt/tests/Clippy on
  macOS, Windows, and Linux; RustSec with warnings denied; and full-history
  Gitleaks ([ci.yml](.github/workflows/ci.yml)).
- Dependabot monitors Cargo and GitHub Actions
  ([dependabot.yml](.github/dependabot.yml)).
- CodeQL is configured for Swift and Rust and activates automatically once the
  repository is public ([codeql.yml](.github/workflows/codeql.yml)).
- GitHub Dependabot alerts and automated security fixes were enabled through the
  repository API. Native secret scanning/CodeQL are unavailable for this private
  repository on its current plan; Gitleaks supplies active secret scanning now,
  and CodeQL's public-repository condition prevents a broken private workflow.
- Workflow actions are pinned to commit SHAs and `actionlint` passes.

### MAGI-QUAL-002 — Resolved: Accessibility refresh cost

- Response refresh uses one-shot adaptive intervals: 250 ms while changing,
  then 500 ms, 1 s, and 2 s, stopping after sustained inactivity
  ([ResponseBinding.swift](OutputLens/ResponseBinding.swift), lines 15–35 and 125–168).
- AX value/layout/children notifications wake stopped or backed-off sessions
  ([ResponseBinding.swift](OutputLens/ResponseBinding.swift), lines 78–122).
- Unchanged frames/content no longer trigger panel re-rendering.
- Refreshes exceeding 2,000 nodes or 50 ms log only node count and duration.
- Policy tests prove the backoff, stop, content-change reset, and notification wake.

### MAGI-QUAL-003 — Resolved: live integration coverage

- `MagiIntegrationHost` exposes a persistent terminal-like AppKit AX control and
  a Return counter ([Main.swift](IntegrationHost/Main.swift)).
- `AccessibilityIntegrationTests` launches it and verifies real direct AX
  write-back, focus transfer, synthetic replacement, and zero Return events
  ([AccessibilityIntegrationTests.swift](OutputLensTests/AccessibilityIntegrationTests.swift)).
- `scripts/test-macos-integration.sh` runs the dedicated signed scheme; it passed
  locally on 2026-08-10.
- Third-party app coverage is tracked in the mandatory manual matrix
  ([COMPATIBILITY.md](COMPATIBILITY.md)).

### MAGI-QUAL-004 — Resolved: stale docs and mutable artifacts

- README, migration, contributor guidance, plan, release notes, and publishing
  instructions now match automatic terminal replacement, clipboard restoration,
  privacy defaults, Linux tray scope, and public signing rules.
- Packaging keeps only the verified immutable ZIP/checksum. A fresh extracted
  archive passes strict code-signature verification.

## Verification record

- Full Swift suite: 75 tests passed with 0 failures; the opt-in live integration
  test was skipped by the normal scheme as designed.
- Live signed AX integration scheme: 1 test passed with no Return event.
- Xcode Analyze: passed.
- Rust: 10 tests, formatting, and all-target/all-feature Clippy with warnings
  denied passed.
- RustSec: `cargo audit --deny warnings` passed with no vulnerability,
  unsoundness, yanked-package, or unmaintained-package findings.
- Packaging: the public-credential guard passed. Fresh Swift and Rust local
  archives passed checksum and extracted strict code-signature verification;
  neither retained a mutable staging app.
- Workflow/shell/plist validation: `actionlint`, `zsh -n`, `plutil -lint`, and
  `git diff --check` passed.
- Full Git history: Gitleaks scanned 25 commits with no secret findings.
- GitHub: vulnerability alerts and automated security fixes are enabled.
