#!/bin/sh
# SessionStart hook for Claude Code.
# Captures the current session ID so the restart wrapper
# knows which session to resume.
#
# Session IDs are scoped per directory to avoid collisions
# when multiple Claude sessions run in different projects.
#
# Requires: jq

CLAUDE_RESTART_DIR="${HOME}/.claude/tmp"

# Scope session file by working directory hash
DIR_HASH=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
SESSION_FILE="${CLAUDE_RESTART_DIR}/session-id-${DIR_HASH}"

# Ensure tmp directory exists
mkdir -p "$CLAUDE_RESTART_DIR"

# Read hook input from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -n "$SESSION_ID" ]; then
  echo "$SESSION_ID" > "$SESSION_FILE"
fi
