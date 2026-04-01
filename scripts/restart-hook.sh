#!/bin/sh
# UserPromptSubmit hook for Claude Code.
# Intercepts "restart" prompts and executes the restart directly,
# bypassing the model entirely (zero tokens consumed).
#
# Requires: jq, CLAUDE_RESTART_ID env var (set by the wrapper)

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')

# Normalize: trim whitespace and lowercase
PROMPT_TRIMMED=$(echo "$PROMPT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')

# Only intercept exact "restart" prompt
if [ "$PROMPT_TRIMMED" != "restart" ]; then
  exit 0
fi

# Need CLAUDE_RESTART_ID from the wrapper
if [ -z "$CLAUDE_RESTART_ID" ]; then
  echo "restart: not running inside claude-wrapper, use /restart instead" >&2
  exit 2
fi

CLAUDE_RESTART_DIR="${HOME}/.claude/tmp"
RESTART_FLAG="${CLAUDE_RESTART_DIR}/restart-flag-${CLAUDE_RESTART_ID}"

# Create flag and kill the process
mkdir -p "$CLAUDE_RESTART_DIR"
touch "$RESTART_FLAG"
kill -TERM $PPID 2>/dev/null

# Block the prompt from reaching the model
printf '{"decision":"block","reason":"Restart initiated via hook"}'
exit 0
