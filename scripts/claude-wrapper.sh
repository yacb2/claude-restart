#!/bin/sh
# Claude Code restart wrapper.
# Runs claude normally. If a restart flag is detected after exit,
# automatically resumes the same session with a fresh process.
#
# Session IDs are scoped per directory so multiple projects
# can use /restart independently without collisions.
#
# This script is POSIX-compatible (works with sh, bash, zsh, dash).

CLAUDE_RESTART_DIR="${HOME}/.claude/tmp"
RESTART_FLAG="${CLAUDE_RESTART_DIR}/restart-flag"

# Scope session file by working directory hash (matches capture-session-id.sh)
DIR_HASH=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
SESSION_FILE="${CLAUDE_RESTART_DIR}/session-id-${DIR_HASH}"

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
    echo "  Restarting Claude Code (resuming session)..."
    echo ""
    # If resume fails (session not found, expired, etc.), fall back to new session
    if ! "$CLAUDE_BIN" --resume "$SESSION_ID"; then
      echo ""
      echo "  Resume failed, starting new session..."
      echo ""
      "$CLAUDE_BIN" "$@"
    fi
  else
    echo ""
    echo "  Restarting Claude Code (new session, no session ID found)..."
    echo ""
    "$CLAUDE_BIN" "$@"
  fi
done
