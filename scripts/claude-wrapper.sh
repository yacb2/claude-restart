#!/bin/sh
# claude-wrapper version: 3
# Unified wrapper for claude-restart and claude-session-handoff.
#
# Runs claude normally. After each exit, checks per-PID flag files in
# ~/.claude/tmp/ and decides what to do next:
#
#   handoff-flag-<pid>  -> launch a fresh session (SessionStart hook injects payload)
#   restart-flag-<pid>  -> resume the same session with --resume <id>
#   (none)              -> exit
#
# If both flags are present, handoff wins (a fresh session takes precedence
# over resuming an old one).
#
# Each wrapper instance is identified by its PID, exported as both
# CLAUDE_RESTART_ID and CLAUDE_HANDOFF_ID so hooks from either tool work.
#
# POSIX-compatible (sh, bash, zsh, dash).
#
# This file is co-owned by:
#   - https://github.com/yacb2/claude-restart
#   - https://github.com/yoelacevedo/claude-session-handoff  (rename as published)
# Both installers write the highest version they ship; the file is byte-for-byte
# identical across repos.

CLAUDE_TMP_DIR="${HOME}/.claude/tmp"
WRAPPER_ID=$$
RESTART_FLAG="${CLAUDE_TMP_DIR}/restart-flag-${WRAPPER_ID}"
SESSION_FILE="${CLAUDE_TMP_DIR}/session-id-${WRAPPER_ID}"
HANDOFF_FLAG="${CLAUDE_TMP_DIR}/handoff-flag-${WRAPPER_ID}"
HANDOFF_PAYLOAD="${CLAUDE_TMP_DIR}/handoff-payload-${WRAPPER_ID}"

export CLAUDE_RESTART_ID="$WRAPPER_ID"
export CLAUDE_HANDOFF_ID="$WRAPPER_ID"

mkdir -p "$CLAUDE_TMP_DIR"

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
  echo "Error: claude binary not found in PATH" >&2
  exit 1
fi

cleanup() {
  rm -f "$RESTART_FLAG" "$SESSION_FILE" "$HANDOFF_FLAG" "$HANDOFF_PAYLOAD"
}
trap cleanup EXIT

# Clear any stale state from a prior process that happened to reuse this PID
rm -f "$RESTART_FLAG" "$SESSION_FILE" "$HANDOFF_FLAG" "$HANDOFF_PAYLOAD"

# First run: pass through original arguments
"$CLAUDE_BIN" "$@"

# Dispatch loop — runs until no flag is set after claude exits
while [ -f "$HANDOFF_FLAG" ] || [ -f "$RESTART_FLAG" ]; do
  if [ -f "$HANDOFF_FLAG" ]; then
    # Handoff wins over restart if both were somehow set.
    rm -f "$HANDOFF_FLAG" "$RESTART_FLAG" "$SESSION_FILE"

    if [ ! -s "$HANDOFF_PAYLOAD" ]; then
      echo ""
      echo "  ⚠ Handoff sin payload — la sesión nueva arranca limpia, sin contexto sembrado."
      echo "    Si querías preservar contexto, pide 'handoff: <texto>' o invoca el skill"
      echo "    de handoff para que Claude genere el prompt antes de cerrar la sesión."
      echo ""
    else
      PAYLOAD_BYTES=$(wc -c < "$HANDOFF_PAYLOAD" | tr -d ' ')
      echo ""
      echo "  ↻ Handoff — iniciando sesión nueva con ${PAYLOAD_BYTES} bytes de contexto sembrado…"
      echo ""
    fi

    # If a payload was seeded, pass an initial prompt as a positional arg so the
    # new session starts processing automatically without waiting for the user
    # to type. SessionStart still fires first and injects the handoff as
    # additionalContext; this prompt becomes the model's first user message.
    if [ -n "$PAYLOAD_BYTES" ]; then
      "$CLAUDE_BIN" "continue"
    else
      "$CLAUDE_BIN"
    fi
    continue
  fi

  # Restart path
  rm -f "$RESTART_FLAG"

  SESSION_ID=""
  if [ -f "$SESSION_FILE" ]; then
    SESSION_ID=$(cat "$SESSION_FILE")
  fi

  if [ -n "$SESSION_ID" ]; then
    SESSION_JSONL=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" 2>/dev/null | head -1)
    if [ -n "$SESSION_JSONL" ]; then
      FILE_SIZE=$(wc -c < "$SESSION_JSONL" | tr -d ' ')
      SIZE_MB=$((FILE_SIZE / 1048576))
      if [ "$SIZE_MB" -ge 2 ]; then
        echo ""
        echo "  ⚠ Large session detected (${SIZE_MB}MB). Resume will reload the full"
        echo "    conversation history — Claude Code compaction is in-memory only and"
        echo "    is not persisted to disk, so compaction may re-trigger on resume."
      fi
    fi
    echo ""
    echo "  ↻ Restarting Claude Code — resuming session ${SESSION_ID%%-*}…"
    echo ""
    "$CLAUDE_BIN" --resume "$SESSION_ID"
    RESUME_EXIT=$?
    if [ $RESUME_EXIT -ne 0 ] && [ ! -f "$RESTART_FLAG" ] && [ ! -f "$HANDOFF_FLAG" ]; then
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
