#!/bin/sh
# UserPromptSubmit hook for Claude Code.
# Intercepts "restart" prompts and executes the restart directly,
# bypassing the model entirely (zero tokens consumed).
#
# Requires: CLAUDE_RESTART_ID env var (set by the wrapper)
# Optional: jq (falls back to grep/sed if missing)
#
# Env vars:
#   CLAUDE_RESTART_LOG         Path to a log file for hook tracing
#   CLAUDE_RESTART_FORCE_AFTER Seconds before SIGKILL fallback (default: 3)

log() {
  if [ -n "$CLAUDE_RESTART_LOG" ]; then
    printf '%s [restart-hook] %s\n' "$(date '+%H:%M:%S')" "$1" >> "$CLAUDE_RESTART_LOG"
  fi
}

INPUT=$(cat)

# Extract prompt — prefer jq, fall back to grep/sed
if command -v jq >/dev/null 2>&1; then
  PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
else
  PROMPT=$(echo "$INPUT" | grep -o '"prompt":"[^"]*"' | head -1 | sed 's/^"prompt":"//;s/"$//')
fi

# Normalize: trim whitespace and lowercase
PROMPT_TRIMMED=$(echo "$PROMPT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')

# Only intercept exact "restart" prompt
if [ "$PROMPT_TRIMMED" != "restart" ]; then
  exit 0
fi

log "intercepted restart prompt"

# --- Verify wrapper is live ---

if [ -z "$CLAUDE_RESTART_ID" ]; then
  MSG="restart is not available — this session was started without the restart wrapper."
  MSG="$MSG Start a new terminal and run claude to use restart."
  log "blocked: CLAUDE_RESTART_ID not set"
  printf '{"decision":"block","reason":"%s"}' "$MSG"
  exit 0
fi

# Guard against stale or inherited env vars (SSH forwarding, tmux, manual
# export) — verify the wrapper process is actually alive.
if ! kill -0 "$CLAUDE_RESTART_ID" 2>/dev/null; then
  MSG="restart is not available — wrapper PID $CLAUDE_RESTART_ID is not running (stale env var?)."
  MSG="$MSG Start a new terminal and run claude to use restart."
  log "blocked: wrapper PID $CLAUDE_RESTART_ID not alive"
  printf '{"decision":"block","reason":"%s"}' "$MSG"
  exit 0
fi

# --- Execute restart ---

CLAUDE_RESTART_DIR="${HOME}/.claude/tmp"
RESTART_FLAG="${CLAUDE_RESTART_DIR}/restart-flag-${CLAUDE_RESTART_ID}"

mkdir -p "$CLAUDE_RESTART_DIR"
touch "$RESTART_FLAG"

# SIGKILL fallback: if SIGTERM doesn't take effect within the timeout,
# force-kill to prevent the session from hanging indefinitely.
FORCE_AFTER="${CLAUDE_RESTART_FORCE_AFTER:-3}"
(
  sleep "$FORCE_AFTER"
  kill -0 $PPID 2>/dev/null && kill -KILL $PPID 2>/dev/null
) >/dev/null 2>&1 &

kill -TERM $PPID 2>/dev/null
log "sent SIGTERM to PID $PPID (SIGKILL fallback in ${FORCE_AFTER}s)"

# Block the prompt from reaching the model
printf '{"decision":"block","reason":"Restart initiated via hook"}'
exit 0
