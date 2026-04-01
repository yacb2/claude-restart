#!/bin/sh
# Claude Code restart wrapper.
# Runs claude normally. If a restart flag is detected after exit,
# automatically resumes the same session with a fresh process.
#
# Each wrapper instance is identified by its PID (CLAUDE_RESTART_ID).
# The restart flag and session file are scoped per wrapper, so multiple
# sessions — even in the same directory — never collide.
#
# This script is POSIX-compatible (works with sh, bash, zsh, dash).

CLAUDE_RESTART_DIR="${HOME}/.claude/tmp"
WRAPPER_ID=$$
RESTART_FLAG="${CLAUDE_RESTART_DIR}/restart-flag-${WRAPPER_ID}"
SESSION_FILE="${CLAUDE_RESTART_DIR}/session-id-${WRAPPER_ID}"

# Export wrapper ID so the restart command and hooks can reference it
export CLAUDE_RESTART_ID="$WRAPPER_ID"

# Ensure tmp directory exists
mkdir -p "$CLAUDE_RESTART_DIR"

# Find the real claude binary (not a shell function/alias)
find_claude_binary() {
  SAVED_IFS="$IFS"
  IFS=:
  for dir in $PATH; do
    if [ -x "$dir/claude" ]; then
      CLAUDE_BIN="$dir/claude"
      IFS="$SAVED_IFS"
      return 0
    fi
  done
  IFS="$SAVED_IFS"
  return 1
}

CLAUDE_BIN=""
if ! find_claude_binary; then
  echo "Error: claude binary not found in PATH"
  exit 1
fi

# Clean up temp files on exit (normal or interrupted)
cleanup() {
  rm -f "$RESTART_FLAG" "$SESSION_FILE"
}
trap cleanup EXIT

# Clean up any stale restart flag from previous sessions
rm -f "$RESTART_FLAG"

# First run: pass through all original arguments
"$CLAUDE_BIN" "$@"

# After claude exits, check if restart was requested
while [ -f "$RESTART_FLAG" ]; do
  rm -f "$RESTART_FLAG"

  SESSION_ID=""
  if [ -f "$SESSION_FILE" ]; then
    SESSION_ID=$(cat "$SESSION_FILE")
  fi

  if [ -n "$SESSION_ID" ]; then
    echo ""
    echo "  ↻ Restarting Claude Code — resuming session ${SESSION_ID%%-*}…"
    echo ""
    "$CLAUDE_BIN" --resume "$SESSION_ID"
    RESUME_EXIT=$?
    # Only fall back to new session if resume genuinely failed (not a /restart)
    if [ $RESUME_EXIT -ne 0 ] && [ ! -f "$RESTART_FLAG" ]; then
      echo ""
      echo "  ⚠ Resume failed — starting fresh session…"
      echo ""
      "$CLAUDE_BIN" "$@"
    fi
  else
    echo ""
    echo "  ↻ Restarting Claude Code — no session ID found, starting fresh…"
    echo ""
    "$CLAUDE_BIN" "$@"
  fi
done
