#!/bin/sh
# SessionStart hook for Claude Code.
# Captures the current session ID so the restart wrapper
# knows which session to resume.
#
# Session IDs are scoped per wrapper instance (CLAUDE_RESTART_ID)
# so multiple sessions — even in the same directory — never collide.
#
# Requires: jq

CLAUDE_RESTART_DIR="${HOME}/.claude/tmp"

# Only save when running inside the restart wrapper
if [ -z "$CLAUDE_RESTART_ID" ]; then
  exit 0
fi

SESSION_FILE="${CLAUDE_RESTART_DIR}/session-id-${CLAUDE_RESTART_ID}"

# Ensure tmp directory exists
mkdir -p "$CLAUDE_RESTART_DIR"

# Read hook input from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -n "$SESSION_ID" ]; then
  echo "$SESSION_ID" > "$SESSION_FILE"
fi
