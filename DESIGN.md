# Output Lens — Product and Technical Design

Status: Draft for discussion

## Problem

Codex and Claude Code desktop output is difficult to read because the text is small and visually thin. macOS screen zoom enlarges the interface, but it also enlarges surrounding UI, preserves long line lengths, and does not improve font weight or text layout.

Output Lens should make one model response comfortably readable without changing the Codex or Claude application itself.

## Goals

- Enlarge one complete model response with one modified click.
- Display it in a persistent panel floating over, and visually attached to, the source application.
- Use larger, heavier text while retaining the response's basic structure.
- Keep the panel connected to the exact selected response while that response streams.
- Replace the displayed response when the user selects another one.
- Support Codex and Claude desktop first.

## Non-goals for the first version

- Terminal, VS Code, Cursor, or browser support.
- Pixel-perfect reproduction of every Markdown style and interactive control.
- A full font and theme settings system.
- Editing or sending prompts from the reading panel.
- Modifying or injecting code into Codex or Claude.

## Primary interaction

1. The user holds the configured modifier and clicks anywhere in a model response.
2. Output Lens finds the complete response containing the clicked text.
3. A floating panel opens over the source application's right side.
4. The panel shows the whole response using a readable default type style.
5. If the response is still streaming, the panel updates from the same bound response.
6. Selecting another response replaces the panel content.

Default trigger: **Option-click**.

The trigger is configurable. The first version should support standard macOS modifier combinations; support for a non-modifier key such as `M` plus click needs a separate interaction mode because it can interfere with typing.

## Panel behavior

- The panel is visually attached to the source window rather than behaving like an unrelated app window.
- It floats over the right side of Codex or Claude and moves with that window.
- It is resizable and scrollable.
- It stays open until closed or until the source window disappears.
- It is shown only with its source application, so it does not cover unrelated apps.
- Selecting a new response immediately replaces the previous response.
- While the response streams, the panel follows new text only if the user is already near the bottom. Manual scrolling is not interrupted.

Initial typography:

- Prose: system accessibility-friendly sans serif, 24 pt, semibold.
- Code: system monospaced font, 21 pt, medium.
- Line spacing: approximately 1.45.
- Comfortable inner padding and a constrained line width.
- Light and dark appearance follow the source app/system appearance.

Font selection and detailed appearance controls are deferred until the core connection is reliable.

## Source connection

The panel must bind to the selected response, not to "the latest text on screen."

On activation, Output Lens records:

- Source application bundle identifier and process.
- Source window.
- Accessibility element and ancestor representing the complete response.
- Screen position, response section index, and a bounded text-prefix identity
  check used to recover the element if the app rebuilds during streaming. This
  identity data remains in memory and is never exported in diagnostics.

It then subscribes to macOS Accessibility change notifications for that element. Updates are accepted only when they belong to the same application, window, response container, and text sequence. A normal streaming update should extend or revise the bound response; it must never silently switch to a neighboring response.

If the application destroys and recreates the accessibility element, Output Lens attempts a constrained recovery in the same window near the original location and verifies the in-memory text sequence. If identity cannot be established confidently, the panel keeps the last confirmed text and shows a small **Connection paused** indicator instead of displaying possibly incorrect content.

## Technical approach

Build a native macOS menu-bar application in Swift using AppKit.

- A global event monitor detects the configured modified click.
- macOS Accessibility APIs locate the element under the pointer and walk upward to the complete response container.
- `AXObserver` notifications drive streaming updates.
- A borderless `NSPanel` provides the attached floating reading surface.
- The application observes source-window movement, resizing, focus, and closure to keep the panel attached.
- All extracted text remains local on the Mac.

Verified initial application targets on the development Mac:

- Codex: `com.openai.codex`
- Claude: `com.anthropic.claudefordesktop`

Screen capture and OCR are fallback options only if an application's accessibility tree does not expose usable response text. They are less desirable because OCR is slower, formatting is harder to recover, and streaming identity is weaker.

## MVP validation

The design is successful when:

1. Option-clicking any completed Codex or Claude model response shows the whole correct response.
2. A streaming response updates in the panel without switching to another response.
3. Clicking a different response replaces the panel content.
4. The panel remains attached while its source window moves or resizes.
5. The panel does not appear over unrelated applications.
6. Prose and code are materially larger and heavier than in the source application.
7. Copying text from the panel preserves plain text and code indentation.

## Delivery sequence

1. Accessibility feasibility spike for both apps.
2. Static response selection and floating panel.
3. Stable streaming connection and recovery behavior.
4. Window attachment, scrolling, and typography polish.
5. Configurable trigger.
6. Terminal and additional application support.

## Open design decisions

- Exact panel width and whether the user can switch between right-side and centered placement.
- Whether the panel should temporarily hide or remain visible when the source app loses focus.
- Source highlighting: resolved — briefly outline the selected response after activation.
- Final product name and icon.
