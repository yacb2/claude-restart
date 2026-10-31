#!/bin/sh
# Regression tests for the restart (resume) branch of scripts/claude-wrapper.sh.
#
# smoke.sh checks the installer protocol and never runs the dispatch loop. This
# drives the loop with a stub `claude` on PATH that stages a restart through the
# wrapper's per-PID flag files (keyed off $CLAUDE_RESTART_ID, the wrapper's
# exported contract) and logs one line of argv per invocation, so the number of
# sessions the wrapper launches is observable.
#
# The wrapper is byte-identical with claude-session-handoff's copy, whose
# tests/wrapper-dispatch.sh carries the same table next to its handoff checks.
#
# Usage: ./tests/wrapper-dispatch.sh
set -u

WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/scripts/claude-wrapper.sh"
PASS=0
FAIL=0
ok()      { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no()      { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
summary() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; }

[ -f "$WRAPPER" ] || { echo "wrapper not found: $WRAPPER"; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Each scenario gets its own HOME so one row's argv.log cannot feed another's.
scenario() {
  SHOME="$SANDBOX/$1"
  SBIN="$SHOME/bin"
  mkdir -p "$SBIN" "$SHOME/.claude/tmp"
}

# A resume killed by a signal is a close, not a failed resume.
#    Observed 2026-10-31: SIGTERM to a `claude --resume <id>` launched by the
#    restart branch (exit 143) made the wrapper start a brand-new session; seven
#    sessions respawned that way. The fresh fallback is for a resume that
#    genuinely failed (1..127); 128 and above is a signal death and ends the
#    loop. One row self-signals so the shell's 128+n report is exercised; the
#    rest use `exit N`, because claude runs as an async list and so inherits
#    SIGINT ignored — a `kill -INT` row would not die and would pass for the
#    wrong reason. The wrapper only ever sees the integer.
#    Each row asserts the wrapper's exit status as well: if `kill -TERM $$`
#    did not land, the stub's `exit TERM` returns 255 (bash 3.2 as sh) and the
#    count alone would stay green. RESTART_TERM is the restart hook's own shape
#    (flag touched, then SIGTERM): it must resume again, so a fix that leaves
#    the loop on any signal (`-ge 128 ... break`) fails there.
#    Stub: invocation 1 stages a restart, invocation 2 is the resume and does
#    the row's action, invocation 3 (fallback or second resume) does nothing.
for ROW in "TERM 2 143" "0 2 0" "1 3 0" "127 3 0" "128 2 128" "130 2 130" \
           "137 2 137" "RESTART_TERM 3 0"; do
  set -- $ROW
  ACTION=$1; WANT=$2; WANT_RC=$3
  scenario "resume_$ACTION"
  cat > "$SBIN/claude" <<'STUB'
#!/bin/sh
TMP="$HOME/.claude/tmp"
printf '%s\n' "$*" >> "$TMP/argv.log"
N=$(( $(wc -l < "$TMP/argv.log") ))
case "$N" in
  1) printf 'sess-1' > "$TMP/session-id-$CLAUDE_RESTART_ID"
     touch "$TMP/restart-flag-$CLAUDE_RESTART_ID"
     exit 0 ;;
  2) case "$RESUME_ACTION" in
       TERM) kill -TERM $$ ;;
       RESTART_TERM) touch "$TMP/restart-flag-$CLAUDE_RESTART_ID"
                     kill -TERM $$ ;;
     esac
     exit "$RESUME_ACTION" ;;
esac
exit 0
STUB
  chmod +x "$SBIN/claude"
  RESUME_ACTION=$ACTION HOME="$SHOME" PATH="$SBIN:$PATH" sh "$WRAPPER" >/dev/null 2>&1
  RC=$?
  GOT=$(( $(wc -l < "$SHOME/.claude/tmp/argv.log") ))
  if [ "$GOT" = "$WANT" ] && [ "$RC" = "$WANT_RC" ]; then
    ok "resume ending in $ACTION -> $WANT invocations, wrapper exits $WANT_RC"
  else
    no "resume ending in $ACTION: expected $WANT invocations and exit $WANT_RC, got $GOT and exit $RC (log: $(tr '\n' '|' < "$SHOME/.claude/tmp/argv.log"))"
  fi
done
IN3=$(sed -n 3p "$SANDBOX/resume_RESTART_TERM/.claude/tmp/argv.log")
if [ "$IN3" = "--resume sess-1" ]; then
  ok "a restart requested during a resume resumes the same session again"
else
  no "restart during a resume: invocation 3 should be '--resume sess-1', got '$IN3'"
fi

summary
[ "$FAIL" = 0 ]
