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
#   CLAUDE_RESTART_FORCE_AFTER Seconds before SIGKILL fallback (disabled by default)

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
  PROMPT=$(echo "$INPUT" | grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/^"prompt"[[:space:]]*:[[:space:]]*"//;s/"$//')
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
# export) — verify the wrapper is an ancestor of the current process, not
# merely alive. A nested Claude session or tmux pane can inherit a live
# CLAUDE_RESTART_ID that belongs to a different wrapper; kill -0 alone
# would pass but the restart flag would go to the wrong wrapper.
#
# Known limitation: if a nested Claude is started without going through
# the wrapper (e.g. `command claude` inside an existing wrapped session),
# the outer wrapper IS in the ancestor chain, so this check passes. A
# complete fix requires a per-invocation token set by the wrapper — out
# of scope for this hook-only change. The ancestor check is still strictly
# better than the prior code (which accepted any non-empty env var).
is_wrapper_ancestor() {
  _pid=$$
  while true; do
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    case "$_pid" in
      ''|0|1) return 1 ;;
    esac
    [ "$_pid" = "$CLAUDE_RESTART_ID" ] && return 0
  done
}

if ! is_wrapper_ancestor; then
  MSG="restart is not available — wrapper PID $CLAUDE_RESTART_ID is not an ancestor of this session (stale or inherited env var?)."
  MSG="$MSG Start a new terminal and run claude to use restart."
  log "blocked: wrapper PID $CLAUDE_RESTART_ID not in ancestor chain"
  printf '{"decision":"block","reason":"%s"}' "$MSG"
  exit 0
fi

# --- Execute restart ---

CLAUDE_RESTART_DIR="${HOME}/.claude/tmp"
RESTART_FLAG="${CLAUDE_RESTART_DIR}/restart-flag-${CLAUDE_RESTART_ID}"

mkdir -p "$CLAUDE_RESTART_DIR"
touch "$RESTART_FLAG"

# SIGKILL fallback: opt-in via CLAUDE_RESTART_FORCE_AFTER (seconds).
# Disabled by default to avoid interrupting SessionEnd hooks or slow
# cleanup. Set to e.g. 10 if you hit cases where SIGTERM hangs.
FORCE_AFTER="${CLAUDE_RESTART_FORCE_AFTER:-}"
if [ -n "$FORCE_AFTER" ]; then
  (
    sleep "$FORCE_AFTER"
    kill -0 $PPID 2>/dev/null && kill -KILL $PPID 2>/dev/null
  ) >/dev/null 2>&1 &
fi

kill -TERM $PPID 2>/dev/null
log "sent SIGTERM to PID $PPID${FORCE_AFTER:+ (SIGKILL fallback in ${FORCE_AFTER}s)}"

# Block the prompt from reaching the model
printf '{"decision":"block","reason":"Restart initiated via hook"}'
exit 0
