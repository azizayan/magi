# Magi: Response Selection and Semi-Code Editor Plan

Status: Phases 1–4 implemented (snapshot diagnostics + fixture export, adapter-based response boundaries with no whole-conversation fallback, Semi-Code Editor with direct write-back, and explicit-paste Terminal/iTerm2 support). Phase 5 (native Windows/Linux adapters) remains open, as does live validation against current Codex/Claude and terminal builds using captured fixtures.

## Problem

Option-clicking the latest Codex response currently opens the entire chat history instead of only the model response that was clicked.

The current macOS implementation starts with the Accessibility element beneath the pointer, walks through its ancestors, and selects an ancestor that appears to contain a response. It uses readable text size and nearby action names such as `Copy response` as signals.

This is unreliable in the current Codex Accessibility tree:

- The element under the pointer may be only one paragraph, list item, or code block.
- The nearest ancestor containing response controls may be the whole conversation.
- Repeated controls can exist below one conversation container.
- Text length ratios are only guesses; a long response and a short conversation can violate them.
- Codex and Claude can change their internal Accessibility hierarchy between releases.

The result is a false boundary: Magi correctly finds readable text, but assigns it to the conversation rather than to one assistant message.

## Desired behavior

### Reader mode

When the user Option-clicks model output:

1. Identify the exact assistant message containing the click.
2. Display that complete message, including paragraphs, lists, and code blocks.
3. Exclude previous prompts, previous responses, activity labels, and message controls.
4. Keep the panel bound to that same message while it streams.
5. If the boundary cannot be identified confidently, do not show the whole conversation. Keep the previous content and report that the response could not be identified.

The click location determines the response. “Latest response” is a common case, not a reason to silently select a different response.

### Editor mode

When the user Option-clicks an editable input area:

1. Open Magi as a large, readable editor.
2. Load the input's current text.
3. Let the user edit it comfortably.
4. Apply the edited text back to the original input without automatically submitting or running it.

This mode is called the **Semi-Code Editor**.

## Proposed response-selection design

### 1. Capture a bounded Accessibility snapshot

For the clicked application and window, capture:

- The hit element and click position.
- Its ancestors up to the source window.
- Descendants of relevant ancestors within a fixed node budget.
- Role, identifier, description, value, frame, parent/child relationship, and action labels.

Log a redacted structural summary in debug builds. Text should be represented by length and a short fingerprint, not full private conversation content.

This snapshot will give us evidence from the actual Codex and Claude trees instead of requiring more length-based guesses.

### 2. Classify the clicked target

Before selecting content, classify the target as:

- `assistantResponse`
- `editableInput`
- `unsupported`

Editable roles and settable value attributes take priority. Otherwise, a click inside readable output enters response selection.

### 3. Use application-specific adapters

Create a small adapter per supported app:

- `CodexResponseAdapter`
- `ClaudeResponseAdapter`

Each adapter receives the same Accessibility snapshot and returns a response boundary and confidence score. Shared traversal and text assembly remain generic.

An app-specific adapter is preferable to one increasingly complex universal heuristic because Codex and Claude expose different trees and can be updated independently.

### 4. Find one message boundary

For the clicked output, derive candidate message sections using these signals:

- Candidate frame contains the click point.
- Candidate contains the hit element.
- Exactly one response-action cluster belongs to the candidate.
- A nearby `Copy response`, `Copy message`, feedback, or message-actions control marks an assistant-message boundary.
- Text fragments form one vertically contiguous section.
- Candidate is the nearest/deepest container satisfying the above conditions.

Penalize or reject candidates that:

- Contain several response-action clusters.
- Contain repeated user/assistant message markers.
- Span most of the conversation viewport.
- Include text both above the previous message boundary and below the next boundary.
- Grow from the clicked content into a conversation-sized ancestor.

The number of action controls must be treated as structural evidence, not deduplicated labels.

### 5. Partition a conversation container when necessary

If Codex exposes only a conversation-level ancestor, do not select that ancestor directly. Partition its descendants into message sections.

Preferred partition method:

1. Locate every response-action cluster in document order.
2. Associate each cluster with its nearest text-bearing sibling or parent section.
3. Compute a vertical range for each message from adjacent section boundaries.
4. Select the section whose range contains the click.
5. Assemble only text fragments inside that section.

For the last model response, the lower boundary is the end of the conversation content. The upper boundary is the end of the preceding user message or the beginning of the last assistant section.

If controls are unavailable, use contiguous descendant groups and geometry as a fallback. Never fall back to returning the complete conversation.

### 6. Optional exact-copy fallback

Some app versions may expose a reliable `Copy response` action but no readable per-message container. In that case, an adapter may offer an explicit fallback that activates the response's own Copy action and reads the resulting clipboard text.

This fallback must:

- Be limited to the action associated with the clicked message.
- Be visible to the user as clipboard-based capture.
- Avoid pretending to maintain a live streaming binding.
- Not silently overwrite and restore unrelated clipboard content.

Direct Accessibility extraction remains the preferred path.

### 7. Bind to message identity

Store a response identity containing:

- Application process and source window.
- Adapter name.
- Response element when stable.
- Message frame and structural path.
- Initial text fingerprint.
- Associated action-control identity.

During streaming, accept an update only if the adapter resolves the same message identity. If identity is lost, pause on the last confirmed text instead of expanding to a parent conversation.

## Semi-Code Editor design

### Interaction

- Option-click model output: open **Reader** mode.
- Option-click an editable input: open **Editor** mode.
- The panel header clearly shows `Reader` or `Editor`.
- Repeating Option-click on a different target replaces the current binding.

The first version uses the existing configurable modified-click trigger.

### Editor layout

- Large monospaced text with comfortable line spacing.
- Multiline editing, text selection, undo/redo, copy/paste, and keyboard navigation.
- Optional soft wrapping, enabled by default.
- A status line showing the source app and whether direct write-back is available.
- Primary action: **Apply to Input**.
- Secondary action: **Cancel**.

The first version is syntax-neutral. Syntax highlighting, completion, formatting, file tabs, and AI rewriting are intentionally deferred. “Semi-code editor” means a focused, readable command/prompt editor, not a full IDE.

### Write-back behavior

For standard editable fields:

1. Retain the source element and its initial value.
2. On **Apply to Input**, verify that the source application, window, and element still exist.
3. Set the element value through Accessibility.
4. Preserve focus in the source input when possible.
5. Keep the editor open if write-back fails and show a useful error.

Magi must never automatically press Enter, submit a prompt, or execute a terminal command. A future **Apply and Submit** action would require a separate explicit design because it can cause external side effects.

### Terminal support

Terminal input is harder than a normal text field. Many terminal applications expose the terminal as a single text area and do not provide the current command as a settable Accessibility value.

Use two adapter paths:

- **Direct input adapter:** for Codex, Claude, and terminals that expose a settable text value.
- **Paste adapter:** for terminals without direct write-back. Applying copies the edited text, focuses the original terminal, clears its current prompt with Control-E then Control-U, and sends Command-V without ever sending Enter. If event creation fails, the copied draft remains available for a manual paste.

The macOS adapter recognizes Terminal, iTerm2, Warp, Ghostty, Kitty, Alacritty,
WezTerm, Hyper, Rio, Wave, and Tabby at the host-app boundary. This makes the
workflow independent of whether the session is running Codex CLI, Claude Code,
or an ordinary shell. Windows Terminal and Linux terminal emulators require
separate UI Automation and AT-SPI adapters.

Mixed applications are detected at the terminal-surface boundary rather than
classifying the whole host as a terminal. VS Code, Cursor, VSCodium, Windsurf,
and Antigravity use their terminal Accessibility description to enter Editor
mode while source editors, sidebars, and other panels remain unaffected.

### Editor state

The editor binding stores:

- Source application and window.
- Source editable element.
- Original text and current draft.
- Selection range when exposed.
- Write-back capability: `direct`, `pasteRequired`, or `unavailable`.

If the source element disappears, the draft remains available so the user does not lose work.

## Architecture changes

Introduce a target-oriented boundary between event capture and the panel:

```text
Modified click
    |
Accessibility snapshot
    |
Target classifier
    |
    +-- Response adapter --> Response binding --> Reader mode
    |
    +-- Input adapter ----> Editor binding ----> Semi-Code Editor mode
```

The enhanced modified-click workflow should be implemented in the existing Swift macOS adapter first because it already owns Accessibility permission and event capture. The Rust app remains the permission-free clipboard reader. Once behavior is stable, shared target and binding concepts can be represented in Rust, while native platform adapters continue to handle Accessibility/UI Automation/AT-SPI.

Rewriting the macOS adapter in Rust would not remove the Accessibility permission requirement.

## Implementation sequence

### Phase 1: collect real tree evidence

- Add bounded structural diagnostics for one failed Codex click and one successful/failed Claude click.
- Record roles, frames, hierarchy, and repeated action clusters without logging full message text.
- Save anonymized fixtures for tests.

Verification: the fixture visibly contains enough information to separate the clicked response from the conversation.

### Phase 2: correct response boundaries

- Introduce the adapter protocol and Codex/Claude adapters.
- Implement action-cluster and geometry-based message partitioning.
- Remove whole-conversation fallback behavior.
- Add fixture-driven tests for:
  - Latest response.
  - An older response.
  - A response containing lists and code blocks.
  - A very long single response.
  - A whole conversation with repeated identical Copy controls.
  - Streaming growth without switching messages.

Verification: Option-clicking any tested assistant message returns only that message; ambiguous selection fails safely.

### Phase 3: Semi-Code Editor for desktop inputs

- Add target classification.
- Add Reader/Editor panel state.
- Add the large multiline editor and draft preservation.
- Implement direct Accessibility write-back for Codex and Claude inputs.
- Add tests for classification, apply, cancellation, stale elements, and failed write-back.

Verification: Option-clicking a Codex or Claude input opens its text in Editor mode, and **Apply to Input** updates the field without submitting it.

### Phase 4: terminal input adapters

- Implemented a conservative paste-required adapter for common macOS terminal
  hosts. Magi starts with an empty draft because terminal Accessibility values
  commonly contain the whole screen buffer, not just the current command.
- **Apply** copies the draft, suppresses Magi's clipboard watcher for that
  self-copy, and returns focus to the terminal. The user performs Paste; Magi
  never synthesizes Paste or Enter.
- Live validation against the installed terminal versions remains.

Verification: a multiline command can be edited in Magi and returned to each supported terminal without being executed.

### Phase 5: cross-platform adapters

- Windows: evaluate UI Automation response and editable-field boundaries.
- Linux: evaluate AT-SPI boundaries across supported desktop environments.
- Keep clipboard Reader mode as the cross-platform baseline.

Verification: claim support only for combinations tested on real operating systems and target apps.

## MVP acceptance criteria

1. Option-clicking the latest Codex response never displays earlier chat history.
2. Option-clicking an older response selects that response rather than always selecting the latest.
3. Long responses, code blocks, and lists remain complete.
4. Streaming updates remain attached to the selected response.
5. Ambiguous boundaries pause or show an error; they never expand to the whole conversation.
6. Option-clicking a Codex or Claude input opens Editor mode with the current text.
7. Applying an edit writes it back without submitting it.
8. Editor drafts survive a lost source binding.
9. Terminal commands are never executed automatically.

## Immediate next step

Capture one anonymized Accessibility-tree fixture from the current Codex version while Option-clicking the latest response shown in the reported failure. Implementing another generic text-length threshold before collecting that fixture would likely repeat the current bug.
