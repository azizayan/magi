# Terminal and CLI Reader

Option-click terminal output to open Reader. Press Option-M while a terminal is
focused to open the Semi-Code Editor. These triggers are intentionally
different so clicking output cannot send replacement keys to a terminal.

## Exact Codex CLI capture

If no `notify` setting exists, add this top-level setting to
`~/.codex/config.toml`, replacing the repository path if Magi was cloned
elsewhere:

```toml
notify = ["/absolute/path/to/magi/scripts/magi-cli-hook.sh", "codex"]
```

Codex supports one notify program. If another integration already owns it,
preserve that command by placing it before `"--"` in Magi's chaining wrapper:

```toml
notify = ["/absolute/path/to/magi/scripts/magi-codex-notify.sh", "/path/to/existing-notifier", "its-fixed-argument", "--"]
```

The wrapper passes Codex's JSON payload to the existing notifier first and then
stores it for Magi. It does not interpret the previous command with a shell.

Codex invokes it after a completed agent turn. Magi uses the supplied final
assistant message only when distinctive text from that response is visible in
the clicked terminal; it never substitutes the newest unrelated response.

## Exact Claude Code capture

Merge this hook into `~/.claude/settings.json` without removing existing hooks:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"/absolute/path/to/magi/scripts/magi-cli-hook.sh\" claude"
          }
        ]
      }
    ]
  }
}
```

Claude sends the completed assistant message to the hook on standard input.

## Generic terminal output

No CLI hook is required for ordinary commands. Magi asks the terminal for the
character at the click point and extracts text between the surrounding shell
prompts. If the terminal does not expose a click position or clear prompt
boundaries, Magi leaves the existing Reader content unchanged instead of
showing the full terminal history.

## Local data

The bridge writes JSON records to
`~/Library/Application Support/Magi/CLI Responses`. The directory is owner-only
(`0700`) and records are owner-readable only (`0600`). When Reader checks the
inbox, records older than seven days and records beyond the newest 100 are
deleted. Magi does not monitor the clipboard for terminal Reader.
