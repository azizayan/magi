# Publishing Magi

Release target (decided): **GitHub release**, **ad-hoc / unsigned** (no Apple
Developer account yet). Magi ships as **one app per platform**:

- **macOS** — the Swift app (both clipboard and Option-click modes), packaged as
  `dist/Magi.app` / `dist/Magi-macos.zip` via `scripts/package-macos.sh`.
- **Windows/Linux** — the Rust clipboard reader, built from source (`cargo run`)
  for this release; packaged binaries are a follow-up.

Notarization, an app icon, and CI are deferred follow-ups, not blockers.

## Critical path (can ship today)

- [x] Both apps build and pass tests (`cargo test`, `xcodebuild … test`).
- [x] `LICENSE` present (MIT, matches `Cargo.toml`).
- [x] Packaging script ad-hoc signs and zips a release artifact.
- [x] README documents install + Gatekeeper bypass for the unsigned build.
- [ ] Final verification pass (below).
- [ ] Commit, push, tag, and create the GitHub release (commands below — run with your go-ahead).

## Step 1 — Final verification

```sh
# macOS app (Swift) — the macOS release artifact
xcodebuild -project OutputLens.xcodeproj -scheme OutputLens \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/output-lens-derived \
  CODE_SIGNING_ALLOWED=NO test
./scripts/package-macos.sh          # → dist/Magi.app + dist/Magi-macos.zip

# Rust reader (Windows/Linux)
cargo build --release
cargo test
cargo clippy --quiet
```

Manual smoke test on `dist/Magi.app`:

1. Start Magi; confirm existing clipboard content is not shown.
2. Enable **Watch Clipboard**, copy a complete response, confirm it appears with
   no Accessibility permission.
3. Select and copy part of the reader text; confirm the reader does not replace
   itself with that fragment.
4. Grant Accessibility, Option-click a response; confirm only that message shows.
5. Option-click an input; edit and **Apply to Input**; confirm it writes back and
   does not submit.
6. Option-click Terminal/iTerm2; confirm **Apply** copies the draft but does not
   paste or execute it automatically.
7. Confirm a link in a rendered response opens in the browser.

## Step 2 — Publish (run when ready)

These are the outward-facing steps. They publish public content, so run them
yourself (or confirm explicitly and I will run them).

```sh
# 1. Land the work on a branch and open it for review, or commit to main directly.
git checkout -b release-0.1.0
git add -A
git commit -m "Prepare Magi 0.1.0 release"
git push -u origin release-0.1.0
# (merge to main via PR, or push main directly if you prefer)

# 2. Tag the release.
git tag v0.1.0
git push origin v0.1.0

# 3. Create the GitHub release with the macOS artifact.
gh release create v0.1.0 \
  dist/Magi-macos.zip \
  --title "Magi 0.1.0" \
  --notes-file RELEASE_NOTES.md
```

Suggested `RELEASE_NOTES.md` outline:

- What Magi is (readable reader for Codex/Claude output).
- macOS: download `Magi-macos.zip`; two modes (permission-free clipboard +
  Option-click). Unsigned build — right-click → Open (link to README).
- Windows/Linux: build the Rust reader from source with `cargo run` for now.

## Deferred follow-ups (not blocking today)

1. **Notarization** — once an Apple Developer ID is available: sign with the
   Developer ID cert, `notarytool submit`, and `stapler staple` the `.app`/DMG.
   Removes the Gatekeeper warning entirely.
2. **App icon** — add an `.icns` and reference it (`CFBundleIconFile`) in
   `packaging/macos/Info.plist`; today the app uses the generic icon.
3. **CI** — `.github/workflows/` is empty by design; add a macOS + Rust matrix
   (`cargo test`/`clippy`, `xcodebuild test`) when the repo token allows workflows.
4. **Bundle identifier** — the macOS app is branded "Magi" but keeps the
   `com.azizemreayan.OutputLens` bundle id (changing it resets the Accessibility
   grant). Unify to `com.azizemreayan.magi` in a later release if desired.
5. **Adapter live validation** — validate the Codex/Claude response-boundary
   adapters against current desktop builds using the **Save Anonymized Click
   Fixture…** menu item, and commit fixtures for regression tests.
6. **Windows/Linux binaries** — currently source-build only; add packaged
   artifacts after per-platform validation.
```
