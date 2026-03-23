#!/bin/sh
# SessionStart hook for Claude Code.
# Captures the current session ID so the restart wrapper
# knows which session to resume.
#
# Requires: jq

CLAUDE_RESTART_DIR="${HOME}/.claude/tmp"
SESSION_FILE="${CLAUDE_RESTART_DIR}/session-id"

# Ensure tmp directory exists
mkdir -p "$CLAUDE_RESTART_DIR"

# Read hook input from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -n "$SESSION_ID" ]; then
  echo "$SESSION_ID" > "$SESSION_FILE"
fi
