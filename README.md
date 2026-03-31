# claude-restart

Add a `/restart` command to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that restarts the session in-place — fresh process, same conversation.

Useful when you need to:
- Pick up a new Claude Code version after an update
- Reload hooks, skills, or plugins you just changed
- Re-inject context after hitting token limits
- Recover from MCP connection issues

> **Related**: [anthropics/claude-code#34320](https://github.com/anthropics/claude-code/issues/34320) — feature request for native `/restart`

## How it works

```
You type /restart inside Claude Code
        │
        ▼
Haiku runs: touch restart-flag && kill -TERM $PPID
        │
        ▼
Claude Code exits cleanly (session is already saved to disk)
        │
        ▼
The wrapper script detects the restart flag
and runs: claude --resume <session-id>
        │
        ▼
Claude Code reappears in the same terminal
with your conversation resumed, fresh hooks, and the latest binary
```

Three components make this work:

1. **Wrapper script** — runs `claude` inside a loop that checks for a restart flag on exit
2. **SessionStart hook** — captures the session ID (scoped per directory) so the wrapper knows what to resume
3. **`/restart` command** — writes the flag and sends SIGTERM (runs on Haiku for speed)

Session IDs are scoped by working directory, so you can run `/restart` in multiple projects simultaneously without collisions.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and in PATH
- [jq](https://jqlang.github.io/jq/) (for parsing hook input)
- Shell: **zsh**, **bash**, or **fish**

## Installation

### Quick install

```bash
git clone https://github.com/yacb2/claude-restart.git
cd claude-restart
./install.sh
```

### What the installer does

1. Copies scripts to `~/.claude/scripts/`
2. Copies the `/restart` command to `~/.claude/commands/`
3. Adds a `claude()` shell function to your rc file (`.zshrc`, `.bashrc`, or fish functions)
4. Adds a `SessionStart` hook to `~/.claude/settings.json`
5. Creates `~/.claude/tmp/` for temp files

The installer is **idempotent** — running it twice won't duplicate anything.

### Manual installation

If you prefer to install manually:

1. Copy `scripts/` to `~/.claude/scripts/` and make them executable
2. Copy `commands/restart.md` to `~/.claude/commands/`
3. Add this to your shell rc file:

```bash
# zsh (~/.zshrc) or bash (~/.bashrc)
claude() {
  ~/.claude/scripts/claude-wrapper.sh "$@"
}
```

```fish
# fish (~/.config/fish/functions/claude.fish)
function claude
  ~/.claude/scripts/claude-wrapper.sh $argv
end
```

4. Add the SessionStart hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/capture-session-id.sh"
          }
        ]
      }
    ]
  }
}
```

### Permissions

If Claude asks for permission to run the `kill` command, allow `Bash(kill:*)` in your settings:

```json
{
  "permissions": {
    "allow": [
      "Bash(kill:*)"
    ]
  }
}
```

## Usage

Open a **new terminal** after installation, then:

```
$ claude
> /restart
```

That's it. Claude exits and comes back automatically with the same conversation.

## Uninstall

```bash
cd claude-restart
./install.sh --uninstall
```

This removes all files, the shell function, and the SessionStart hook.

## Limitations

- **Requires the wrapper**: `/restart` only works when Claude was launched through the wrapper function. If you open Claude some other way (e.g., from an IDE integration that calls the binary directly), the restart flag is written but nothing picks it up.
- **LLM overhead**: The `/restart` command runs on Haiku, which is fast (~2-3s) but not instant. A native implementation would be zero-latency.
- **Session must exist**: On the very first run after install, the SessionStart hook needs to fire once to capture the session ID. If you `/restart` before any hook has run, it falls back to a fresh session.
- **Resume can fail**: If the session file is corrupted or the session was garbage-collected, the wrapper automatically falls back to a fresh session instead of hanging.

## Troubleshooting

- **`/restart` does nothing**: Make sure you opened a new terminal after installing. The `claude()` wrapper function needs to be loaded from your shell rc file.
- **Falls back to new session**: The SessionStart hook hasn't fired yet. Run `/restart` again — the hook fires on resume and captures the ID.
- **Resumes the wrong project's session**: This was fixed in v0.2. Session IDs are now scoped per directory. If you installed an older version, re-run `./install.sh` to update.
- **Windows (WSL)**: The installer works without changes inside WSL. Run it from your WSL terminal.

## How it's built

| File | Purpose |
|------|---------|
| `scripts/claude-wrapper.sh` | POSIX-compatible wrapper that runs `claude` in a restart loop, with automatic fallback if resume fails |
| `scripts/capture-session-id.sh` | SessionStart hook that saves the session ID per directory to `~/.claude/tmp/session-id-<hash>` |
| `commands/restart.md` | Claude Code command (runs on Haiku) that writes the restart flag and sends SIGTERM |
| `install.sh` | Installer with shell detection and `--uninstall` support |

## License

MIT
