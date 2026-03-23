---
description: Restart Claude Code session (exit + auto-resume)
model: haiku
allowed-tools: Bash
---

Run this command immediately, no commentary:

```bash
touch "$HOME/.claude/tmp/restart-flag" && kill -INT $PPID
```
