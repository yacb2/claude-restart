# claude-restart

Add a restart command to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that restarts the session in-place — fresh process, same conversation.

Useful when you need to:
- Pick up a new Claude Code version after an update
- Reload hooks, skills, or plugins you just changed
- Re-inject context after hitting token limits
- Recover from MCP connection issues

> **Related**: [anthropics/claude-code#34320](https://github.com/anthropics/claude-code/issues/34320) — feature request for native `/restart`

## How it works

Two ways to restart, both produce the same result:

### `restart` (recommended — zero tokens)

```
You type "restart" in the prompt
        │
        ▼
UserPromptSubmit hook intercepts it before reaching the model
        │
        ▼
Hook runs: touch restart-flag && kill -TERM $PPID
(prompt is blocked — model never sees it, zero tokens consumed)
        │
        ▼
The wrapper script detects the restart flag
and runs: claude --resume <session-id>
        │
        ▼
Claude Code reappears in the same terminal
with your conversation resumed, fresh hooks, and the latest binary
```

### `/restart` (fallback — sends context to model)

The `/restart` slash command works the same way but goes through the model: Claude reads the command, generates a response, and then executes the kill. This means the **entire conversation context is sent to the model** just to run a `touch` and `kill`.

> **Why not use Haiku for `/restart`?** We originally set `model: haiku` on the command to save tokens, but Haiku has a 200k context window. If your conversation exceeds that, Claude Code tries to compact the conversation to fit Haiku's limit — and fails. The command now uses the session's current model to avoid this, but still consumes input tokens proportional to your conversation size.

**Use `restart` (no slash) whenever possible.** Only fall back to `/restart` if you're not running inside the wrapper (e.g., IDE integrations that call the Claude binary directly).

## Components

Four components make this work:

1. **Wrapper script** — runs `claude` inside a loop that checks for a restart flag on exit
2. **SessionStart hook** — captures the session ID (scoped per wrapper instance) so the wrapper knows what to resume
3. **UserPromptSubmit hook** — intercepts `restart` prompts and executes the restart directly, bypassing the model (zero tokens)
4. **`/restart` command** — fallback that writes the flag and sends SIGTERM through the model

Each wrapper instance gets a unique ID (its PID), so multiple sessions — even in the same project directory — can use `restart` independently without collisions.

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
5. Adds a `UserPromptSubmit` hook for zero-token restart
6. Creates `~/.claude/tmp/` for temp files

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

4. Add the hooks to `~/.claude/settings.json`:

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
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/restart-hook.sh"
          }
        ]
      }
    ]
  }
}
```

### Permissions

If Claude asks for permission to run the `kill` command when using `/restart` (the slash command fallback), allow `Bash(kill:*)` in your settings:

```json
{
  "permissions": {
    "allow": [
      "Bash(kill:*)"
    ]
  }
}
```

The `restart` hook (no slash) doesn't need this permission since it runs outside the model.

## Usage

Open a **new terminal** after installation, then:

```
$ claude
> restart
```

That's it. Claude exits and comes back automatically with the same conversation.

## Uninstall

```bash
cd claude-restart
./install.sh --uninstall
```

This removes all files, the shell function, and all hooks.

## Limitations

- **Requires the wrapper**: `restart` only works when Claude was launched through the wrapper function. If you open Claude some other way (e.g., from an IDE integration that calls the binary directly), use `/restart` instead.
- **Exact match**: The hook only triggers on the exact word `restart` (case-insensitive). Writing "please restart" or "restart now" won't trigger it — use `/restart` for those cases.
- **Session must exist**: On the very first run after install, the SessionStart hook needs to fire once to capture the session ID. If you restart before any hook has run, it falls back to a fresh session.
- **Resume can fail**: If the session file is corrupted or the session was garbage-collected, the wrapper automatically falls back to a fresh session instead of hanging.
- **Large sessions**: Claude Code compaction is in-memory only and not persisted to disk. When resuming a very large session, Claude Code reloads the full conversation history from the JSONL file, which may trigger re-compaction. The wrapper warns when a session file exceeds 2MB.

## Troubleshooting

- **`restart` does nothing**: Make sure you opened a new terminal after installing. The `claude()` wrapper function needs to be loaded from your shell rc file.
- **Falls back to new session**: The SessionStart hook hasn't fired yet. Run `restart` again — the hook fires on resume and captures the ID.
- **Resumes the wrong session**: Fixed in v0.3. Session IDs are now scoped per wrapper instance (not per directory), so multiple sessions in the same project don't collide. Re-run `./install.sh` to update.
- **Windows (WSL)**: The installer works without changes inside WSL. Run it from your WSL terminal.

## How it's built

| File | Purpose |
|------|---------|
| `scripts/claude-wrapper.sh` | POSIX-compatible wrapper that runs `claude` in a restart loop, with large-session warning and automatic fallback if resume fails |
| `scripts/capture-session-id.sh` | SessionStart hook that saves the session ID per wrapper instance to `~/.claude/tmp/session-id-<pid>` |
| `scripts/restart-hook.sh` | UserPromptSubmit hook that intercepts `restart` prompts and executes the restart directly (zero tokens) |
| `commands/restart.md` | Claude Code slash command fallback that writes the restart flag and sends SIGTERM through the model |
| `install.sh` | Installer with shell detection, hook registration, and `--uninstall` support |

## License

MIT
