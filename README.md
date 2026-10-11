# Magi for Codex

Magi is an open-source macOS reading lens for Codex Desktop. Option-click an
assistant response to open the whole answer in a large, high-contrast floating
panel. Response text stays on your Mac.

This is an early, source-only alpha under the MIT License. The first release
focuses on Codex Desktop response reading. Prompt editing, other applications,
and terminal integrations are experimental and are not part of this alpha's
support promise. Codex interface changes can affect response capture; please
report incomplete or incorrect captures through GitHub Issues.

Magi is an independent project and is not affiliated with OpenAI.

## Install Magi on macOS

Build Magi locally from this repository. No Apple Developer membership,
Developer ID certificate, or notarization is needed for this source build.
You still need Apple's Xcode tools and a Mac running macOS 14 or newer.

### 1. Download the project

Use **Code → Download ZIP** on GitHub and unzip it, or clone the repository:

```sh
git clone https://github.com/azizayan/magi.git
cd magi
```

### 2. Install the build requirements

You need macOS 14 or newer, the full Xcode app, and XcodeGen. Install Xcode
from the Mac App Store, open it once, and allow it to finish installing its
components. Then run:

```sh
xcodebuild -version
brew install xcodegen
```

The first command confirms that the active developer tools point to Xcode. If
`brew` is not installed, follow the instructions at [brew.sh](https://brew.sh),
then install XcodeGen.

### 3. Build and launch Magi

```sh
./build.sh
open /private/tmp/output-lens-build/Debug/OutputLens.app
```

This source build is internally named `OutputLens.app`, but its user-facing
name is Magi. Magi runs behind the text-magnifying-glass icon in the menu bar;
it does not open a normal app window until you use one of its triggers.

### 4. Allow Accessibility access

On first use, open:

**System Settings → Privacy & Security → Accessibility**

Enable **Magi** or **OutputLens**, then return to the app you want to use. This
permission is required because Option-click must identify the response or input
under the pointer. Magi does not use it to submit prompts.

If the first Option-click still does nothing, choose **Quit Magi** from its
menu-bar menu, launch it again, and retry.

## Experimental integrations

The code also includes the integrations below. Only Codex Desktop response
reading is the focus of this alpha; the remaining workflows need independent
live validation.

| Surface | Reader | Editor |
|---|---|---|
| Codex desktop | Assistant responses | Prompt input |
| ChatGPT Classic | Assistant responses | Prompt input |
| Claude desktop | Assistant responses | Prompt input |
| Ollama desktop | Assistant responses | Prompt input |
| Cursor assistant | Assistant responses | Not currently supported |
| Codex CLI and Claude Code CLI | Completed responses | Current terminal input |
| Standalone terminals | Completed prompt-bounded output | Current terminal input |
| VS Code, Cursor, VSCodium, Windsurf, and Antigravity | Integrated terminal output only | Integrated terminal input only |

## The two controls to remember

| What you are using | What you want | Control |
|---|---|---|
| Codex, ChatGPT, Claude, or Ollama desktop | Read a response | **Option-click the response** |
| Codex, ChatGPT, Claude, or Ollama desktop | Edit the input | **Option-click inside the input** |
| Cursor assistant | Read a response | **Option-click the response** |
| Any supported terminal | Read output | **Option-click the output** |
| Any supported terminal | Edit the current input | Press **Option-M**, or **Control-Option-click** inside it |

Terminal inputs use Option-M because most terminal apps expose the prompt and
all visible output as one Accessibility text area. Option-M avoids confusing a
command line with previously printed output.

## Usage by app

### Codex desktop

- **Reader:** Option-click anywhere inside an assistant response. Magi opens
  that complete response and remains attached while it streams.
- **Editor:** Option-click inside the prompt input. Edit the text in Magi and
  choose **Apply to Input**.
- Applying text does not submit the prompt.

### Claude desktop

- **Reader:** Option-click an assistant response.
- **Editor:** Option-click inside Claude's input area, then choose **Apply to
  Input** when finished.
- Applying text does not send the message.

### Cursor

- **Assistant Reader:** Option-click a Cursor assistant response.
- **Integrated terminal Reader:** Option-click completed terminal output.
- **Integrated terminal Editor:** Click or focus the terminal and press
  **Option-M**.
- Cursor's normal source editor and assistant input editor are not currently
  modified by Magi.

### Codex CLI

This works in a standalone terminal or a recognized integrated terminal.

- **Reader:** Option-click text from a completed Codex response.
- **Editor:** Focus the active terminal prompt and press **Option-M**.
- Choose **Apply to Input** to replace the current command. Magi never presses
  Return.

For exact complete responses—including text no longer visible in scrollback—set
up the Codex completion hook in [CLI_INTEGRATION.md](CLI_INTEGRATION.md).

### Claude Code CLI

- **Reader:** Option-click text from a completed Claude Code response.
- **Editor:** Focus its terminal prompt and press **Option-M**.
- Choose **Apply to Input** to replace the current prompt without submitting it.

Enable the Claude Code completion hook in
[CLI_INTEGRATION.md](CLI_INTEGRATION.md) so Magi can retrieve the complete
response beyond visible scrollback.

### Standalone terminal apps

The same controls apply in Terminal, iTerm2, Warp, Ghostty, Kitty, Alacritty,
WezTerm, Hyper, Rio, Wave, and Tabby:

- Option-click completed output to open Reader.
- Focus the prompt and press Option-M to open Editor.
- If macOS does not deliver Option-M, Control-Option-click inside the terminal
  opens the same Editor.

For ordinary shell commands, Magi identifies output using the shell prompts
above and below the clicked block. If it cannot identify both boundaries, it
keeps the previous Reader content instead of showing the entire terminal
history. Custom or multiline prompts, full-screen terminal interfaces, and
still-running commands may not expose safe boundaries; completed Codex and
Claude responses should use the CLI hooks instead.

### VS Code and other integrated terminals

VS Code, Cursor, VSCodium, Windsurf, and Antigravity are supported when the
terminal pane is focused:

- Option-click terminal output for Reader.
- Press Option-M for the terminal Editor.

Option-M is intentionally rejected in normal source editors, browsers,
sidebars, and other unrelated controls.

## Reader controls

- **A− / A+:** decrease or increase the reading size.
- **X:** close the panel. It stays closed until the next trigger.
- Text is selectable.
- `http` and `https` links are clickable.
- The chosen font size is remembered.

If Magi cannot confidently identify one response, it reports the problem and
does not replace a correct response with the whole conversation.

## Editor behavior

The editor provides large monospaced text, normal macOS selection, undo, copy,
cut, and paste.

- **Apply to Input** replaces the source input without submitting it.
- Applying an empty terminal draft clears the current terminal input.
- **Cancel** closes the editor without changing the source.
- Terminal clipboard use is temporary; Magi restores the previous clipboard
  when the safe transaction can be confirmed.

## Troubleshooting

### Nothing happens when I Option-click

- Confirm Magi is running in the menu bar.
- Confirm Accessibility access is enabled for the currently built Magi app.
- Click directly on response text rather than an empty margin or toolbar.

### Option-clicking a terminal input opens Reader

This is expected. Focus the terminal and press **Option-M** to open Editor.

### Option-M does nothing

Option-M only works when a supported standalone terminal or recognized
integrated terminal pane is focused. It is deliberately blocked in unrelated
apps.

With the terminal focused, you can also choose **Open Terminal Editor
(Option-M or Control-Option-click)** from Magi's menu-bar menu. This opens the same editor without
depending on shortcut delivery.

### CLI Reader shows only visible output or cannot find a boundary

Enable the Codex CLI or Claude Code hook described in
[CLI_INTEGRATION.md](CLI_INTEGRATION.md). Start a new CLI session after changing
its configuration.

## Development

Run the macOS test suite:

```sh
xcodebuild -project OutputLens.xcodeproj -scheme OutputLens \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/output-lens-derived \
  CODE_SIGNING_ALLOWED=NO test
```

Build the local macOS package:

```sh
./scripts/package-macos.sh
```

This creates `dist/Magi-macos-UNNOTARIZED.zip`. It is intended for local
testing, not public distribution. See [PUBLISHING.md](PUBLISHING.md) for the
signing and notarization requirements.

The Xcode project is generated from `project.yml`. Edit `project.yml`, then run
`xcodegen generate`; do not manually edit project membership in the generated
`.xcodeproj`.

## More documentation

- [CLI_INTEGRATION.md](CLI_INTEGRATION.md) — exact Codex CLI and Claude Code capture
- [COMPATIBILITY.md](COMPATIBILITY.md) — live app and terminal test matrix
- [DESIGN.md](DESIGN.md) — product and connection design
- [plan.md](plan.md) — implementation plan and current phases
- [PUBLISHING.md](PUBLISHING.md) — public release process

## Privacy and safety

- Extracted text remains local.
- Magi never automatically presses Return or submits a command.
- Terminal CLI hook records are private, limited to the newest 100, and removed
  after seven days.
- Magi does not monitor the clipboard for macOS terminal Reader.

## License

Magi is released under the [MIT License](LICENSE).
