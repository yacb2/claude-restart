#!/bin/sh
# claude-wrapper version: 15
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
# Exit trigger (v4+): instead of killing the wrapper from inside claude
# (which forced the model to emit `kill`, a primitive the new sandbox/
# automode classifier escalates regardless of the allowlist), the skill/
# hook now `touch`es a per-PID sentinel:
#
#   handoff-exit-<pid>  -> background watcher signals SIGTERM to claude
#
# The watcher is launched alongside each claude invocation, polls the
# sentinel, and is the only process that ever calls `kill`. The skill side
# only needs `touch`, which is benign.
#
# v6 pays the two debts that backgrounding claude had quietly incurred:
# its stdin and its exit status. See `exec 3<&0` and LAST_CLAUDE_EXIT below.
#
# v14: the name file may hold the readable title (`ACME-2216 fix login
# flow (8)`), not only the kebab address, so a successor has its display name
# from launch (naming audit D13, BL-087). A valid file is one line of 1..200
# BYTES with no control byte and no leading `-`; the old address is a subset, so
# an old hook still works. A restart re-passes --name only while the transcript
# has no `custom-title` record or the last one is the launch name: /rename writes
# the same record as --name and `--resume --name X` would undo it (probe P10,
# .context/research/2026-11-04-naming-audit/probes.md). Needs jq to compare; with
# no jq a transcript that holds a title record is assumed renamed.
#
# v13: a handoff successor launches with --name <address> when the hooks left
# a valid handoff-name-<pid> file, and a restart passes the remembered address
# again (a bare --resume adopts the display title as the address). See
# run_successor below and tests/wrapper-dispatch.sh. Needs a Claude Code with
# --name and --session-id (2.1.316 has both); there is no runtime gate.
#
# v12: a resume that dies by a signal (exit >= 128: SIGTERM, SIGHUP, SIGKILL)
# was closed by the user or the system; only a real failure (1..127) falls back
# to a fresh session. See RESUME_EXIT below and tests/wrapper-dispatch.sh.
#
# POSIX-compatible (sh, bash, zsh, dash).
#
# This file is co-owned by:
#   - https://github.com/yacb2/claude-restart
#   - https://github.com/yacb2/claude-session-handoff
# Both installers write the highest version they ship; the file is byte-for-byte
# identical across repos.

CLAUDE_TMP_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tmp"
WRAPPER_ID=$$
RESTART_FLAG="${CLAUDE_TMP_DIR}/restart-flag-${WRAPPER_ID}"
SESSION_FILE="${CLAUDE_TMP_DIR}/session-id-${WRAPPER_ID}"
HANDOFF_FLAG="${CLAUDE_TMP_DIR}/handoff-flag-${WRAPPER_ID}"
HANDOFF_PAYLOAD="${CLAUDE_TMP_DIR}/handoff-payload-${WRAPPER_ID}"
HANDOFF_EXIT="${CLAUDE_TMP_DIR}/handoff-exit-${WRAPPER_ID}"
HANDOFF_NAME="${CLAUDE_TMP_DIR}/handoff-name-${WRAPPER_ID}"

export CLAUDE_RESTART_ID="$WRAPPER_ID"
export CLAUDE_HANDOFF_ID="$WRAPPER_ID"

mkdir -p "$CLAUDE_TMP_DIR"

# Hold the wrapper's own stdin on fd 3 so claude can be given it explicitly.
#
# run_claude backgrounds claude to run the exit watcher alongside it, and POSIX
# assigns /dev/null to the stdin of an asynchronous list when job control is
# off — which it is in a script — so `cat notes.md | claude -p …` reached claude
# with no input and no error. Since the rc block replaces `claude` globally,
# that was every piped or redirected use, not just the handoff flow.
#
# The rule applies only "before any explicit redirections", so `<&3` at the
# launch site wins. `0<&0` would not: a self-dup is exactly the form a shell may
# treat as a no-op.
exec 3<&0

# Status of the most recent claude run. The script's last command is the
# dispatch `while` loop, whose status says nothing about claude — and a loop
# whose body never ran exits 0 — so the wrapper exited 0 unconditionally and
# `claude -p … || handle_error` could never take the error branch.
LAST_CLAUDE_EXIT=0

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
  rm -f "$RESTART_FLAG" "$SESSION_FILE" "$HANDOFF_FLAG" "$HANDOFF_PAYLOAD" "$HANDOFF_EXIT" "$HANDOFF_NAME"
}
trap cleanup EXIT

# Clear any stale state from a prior process that happened to reuse this PID
rm -f "$RESTART_FLAG" "$SESSION_FILE" "$HANDOFF_FLAG" "$HANDOFF_PAYLOAD" "$HANDOFF_EXIT" "$HANDOFF_NAME"

# run_claude — launch claude with a background watcher that signals SIGTERM
# when the per-PID handoff-exit sentinel appears. This keeps `kill` out of
# the model's tool surface (the skill only needs `touch`).
run_claude() {
  rm -f "$HANDOFF_EXIT"

  "$CLAUDE_BIN" "$@" <&3 &
  CLAUDE_PID=$!

  (
    while kill -0 "$CLAUDE_PID" 2>/dev/null; do
      if [ -e "$HANDOFF_EXIT" ]; then
        kill -TERM "$CLAUDE_PID" 2>/dev/null
        exit 0
      fi
      sleep 0.5
    done
  ) &
  WATCHER_PID=$!

  wait "$CLAUDE_PID"
  CLAUDE_EXIT=$?
  kill "$WATCHER_PID" 2>/dev/null
  wait "$WATCHER_PID" 2>/dev/null
  rm -f "$HANDOFF_EXIT"
  # Recorded as well as returned: callers inside the dispatch loop discard the
  # return value, and the loop is the last thing the script runs.
  LAST_CLAUDE_EXIT=$CLAUDE_EXIT
  return $CLAUDE_EXIT
}

# A handoff successor keeps the launch's model and effort (v9). Only the launch
# flags are visible here: a /model change inside the session is not.
INHERIT_MODEL=""
INHERIT_EFFORT=""
_prev=""
for _arg in "$@"; do
  case "$_prev" in
    --model) INHERIT_MODEL=$_arg ;;
    --effort) INHERIT_EFFORT=$_arg ;;
  esac
  case "$_arg" in
    --model=*) INHERIT_MODEL=${_arg#--model=} ;;
    --effort=*) INHERIT_EFFORT=${_arg#--effort=} ;;
  esac
  _prev=$_arg
done

# The name of the session this wrapper is running, when a handoff named it.
# Empty for a root session, which keeps its automatic name.
SESSION_NAME=""
# The session id that name was given to; a restart only re-passes the name
# while the session it resumes is that one (/resume or /clear moves on) and no
# human has renamed it since (see the restart branch).
SESSION_NAME_ID=""

run_successor() {
  # The hooks write the display name (v14; the typeable address before). Valid:
  # one line, 1..200 bytes, no byte in 0x00-0x1f or 0x7f, first char not "-".
  # Anything else is ignored, and the new session is then not that name, so the
  # old one is forgotten. Bytes, not characters: ${#} counts characters in a
  # UTF-8 bash and bytes in dash, so wc -c under LC_ALL=C does the counting.
  SESSION_NAME=""
  SESSION_NAME_ID=""
  if [ -f "$HANDOFF_NAME" ]; then
    # A NUL would be dropped silently by $(...), so look for it in the file.
    _raw=$(wc -c < "$HANDOFF_NAME" | tr -d ' ')
    _nonul=$(LC_ALL=C tr -d '\000' < "$HANDOFF_NAME" | wc -c | tr -d ' ')
    # Whole file: a second line puts a newline in the name, refused below
    # (the contract is one line). Trailing newlines are all dropped here, so
    # "name" followed by blank lines is accepted as "name" (harmless).
    SESSION_NAME=$(cat "$HANDOFF_NAME")
    rm -f "$HANDOFF_NAME"
    _len=$(printf '%s' "$SESSION_NAME" | LC_ALL=C wc -c | tr -d ' ')
    _clean=$(printf '%s' "$SESSION_NAME" | LC_ALL=C tr -d '\001-\037\177' | wc -c | tr -d ' ')
    # (an empty name needs no test of its own: the -n guard below skips it)
    if [ "$_raw" != "$_nonul" ] || [ "$_len" -gt 200 ] || [ "$_len" != "$_clean" ]; then
      SESSION_NAME=""
    fi
    case "$SESSION_NAME" in
      -*) SESSION_NAME="" ;;
    esac
  fi
  if [ -n "$SESSION_NAME" ]; then
    # The id is chosen here so the restart can tell this session from a later
    # one. Without a way to make one, the name is not passed at all.
    if command -v uuidgen >/dev/null 2>&1; then
      SESSION_NAME_ID=$(uuidgen | tr 'A-Z' 'a-z')
    elif [ -r /proc/sys/kernel/random/uuid ]; then
      SESSION_NAME_ID=$(cat /proc/sys/kernel/random/uuid)
    fi
    if [ -n "$SESSION_NAME_ID" ]; then
      set -- --session-id "$SESSION_NAME_ID" --name "$SESSION_NAME" "$@"
    else
      SESSION_NAME=""
    fi
  fi
  [ -n "$INHERIT_EFFORT" ] && set -- --effort "$INHERIT_EFFORT" "$@"
  [ -n "$INHERIT_MODEL" ] && set -- --model "$INHERIT_MODEL" "$@"
  run_claude "$@"
}

# First run: pass through original arguments
run_claude "$@"

# Dispatch loop — runs until no flag is set after claude exits
while [ -f "$HANDOFF_FLAG" ] || [ -f "$RESTART_FLAG" ]; do
  if [ -f "$HANDOFF_FLAG" ]; then
    # Handoff wins over restart if both were somehow set.
    rm -f "$HANDOFF_FLAG" "$RESTART_FLAG" "$SESSION_FILE"

    # One test, one branch. An earlier version tested the payload twice — once
    # via `[ -s "$HANDOFF_PAYLOAD" ]` to pick the message, then again via a
    # `PAYLOAD_BYTES` variable to pick the launch form — and the variable was
    # never reset per iteration, so a payload-less handoff following a seeded
    # one inherited the previous value and relaunched with the kickoff prompt
    # while printing "arranca limpia". Nothing between the two tests touches
    # the payload (the next session's SessionStart hook consumes it, and that
    # session has not started), so they were the same test. Folding them makes
    # the stale carry structurally impossible rather than patched.
    # Covered by tests/wrapper-dispatch.sh.
    if [ -s "$HANDOFF_PAYLOAD" ]; then
      PAYLOAD_BYTES=$(wc -c < "$HANDOFF_PAYLOAD" | tr -d ' ')
      echo ""
      echo "  Handoff — starting a new session with ${PAYLOAD_BYTES} bytes of seeded context…"
      echo ""
      # A seeded payload gets an initial prompt as a positional arg so the new
      # session starts processing without waiting for the user to type.
      # SessionStart still fires first and injects the handoff as
      # additionalContext; this prompt becomes the model's first user message.
      # A sentence, not a bare "continue", so it does not read as typed by the
      # owner. Usage readouts match it as the kickoff (mine-handoff-triggers.py,
      # aidex usage-retro prompt_kinds.py).
      run_successor "Continue from the handoff brief."
    else
      echo ""
      echo "  ⚠ Handoff without payload — the new session starts clean, with no seeded context."
      echo "    If you wanted to keep context, ask for 'handoff: <text>' or invoke the handoff skill"
      echo "    so Claude writes the prompt before closing the session."
      echo ""
      run_successor
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
    SESSION_JSONL=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name "${SESSION_ID}.jsonl" 2>/dev/null | head -1)
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
    echo "  Restarting Claude Code — resuming session ${SESSION_ID%%-*}…"
    echo ""
    # Re-pass the launch name only if no human renamed the session since launch
    # (P10): the last custom-title record is the current title, since the pair
    # is re-appended on every flush. None, or one equal to the launch name
    # (compared after JSON decoding, whatever the key order), means no rename.
    # An empty or missing customTitle decodes to "" or "null": empty re-passes,
    # "null" omits. No jq means the title cannot be decoded: a transcript with a
    # title record is then assumed renamed, one without still re-passes.
    KEEP_NAME=0
    if [ -n "$SESSION_NAME" ] && [ "$SESSION_ID" = "$SESSION_NAME_ID" ]; then
      if [ -z "$SESSION_JSONL" ]; then
        KEEP_NAME=1
      elif command -v jq >/dev/null 2>&1; then
        # Compared inside jq: a line that is not JSON is skipped, not fatal, and a
        # title holding a newline is compared whole.
        KEEP_NAME=$(grep -a '"type":"custom-title"' "$SESSION_JSONL" | jq -nrR --arg n "$SESSION_NAME" \
          '[inputs | fromjson? | objects | select(.type == "custom-title") | .customTitle]
           | if length == 0 or last == $n or last == "" then 1 else 0 end' 2>/dev/null)
        [ "$KEEP_NAME" = 1 ] || KEEP_NAME=0
      elif ! grep -aq '"type":"custom-title"' "$SESSION_JSONL"; then
        KEEP_NAME=1
      fi
    fi
    if [ "$KEEP_NAME" = 1 ]; then
      run_claude --resume "$SESSION_ID" --name "$SESSION_NAME"
    else
      run_claude --resume "$SESSION_ID"
    fi
    RESUME_EXIT=$?
    if [ $RESUME_EXIT -ne 0 ] && [ $RESUME_EXIT -lt 128 ] && [ ! -f "$RESTART_FLAG" ] && [ ! -f "$HANDOFF_FLAG" ]; then
      echo ""
      echo "  ⚠ Resume failed — starting fresh session…"
      echo ""
      SESSION_NAME=""
      SESSION_NAME_ID=""
      run_claude "$@"
    fi
  else
    echo ""
    echo "  Restarting Claude Code — no session ID found, starting fresh…"
    echo ""
    SESSION_NAME=""
    SESSION_NAME_ID=""
    run_claude "$@"
  fi
done

exit "$LAST_CLAUDE_EXIT"
