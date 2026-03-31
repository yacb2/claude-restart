---
description: Restart Claude Code session (exit + auto-resume)
model: haiku
allowed-tools: Bash
---

First, say exactly "↻ Session restarted" (nothing else). Then use the Bash tool to run: touch "$HOME/.claude/tmp/restart-flag" && kill -TERM $PPID

Do NOT print the command. Do NOT explain. Just the message, then execute.
