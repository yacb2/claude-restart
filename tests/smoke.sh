#!/bin/sh
# Smoke test for the shared-wrapper coordination between
# claude-restart and claude-session-handoff installers.
#
# Verifies (in an isolated sandbox, no real $HOME/.claude touched):
#   1. Install handoff then restart -> shared block has both in registered-by,
#      wrapper installed once, both hook sets present in settings.json.
#   2. Install restart then handoff -> same result (order-independence).
#   3. Uninstall one -> block keeps the other; wrapper kept.
#   4. Uninstall both -> block removed; wrapper removed.
#   5. Pre-existing legacy `# claude-restart: start` block gets migrated.
#   6. Wrapper version comparison (lower-version installer keeps the
#      already-installed higher-version wrapper).
#
# Does NOT exercise the runtime end-to-end (SIGTERM to PPID, fresh claude
# launch) — those require a real TTY and a real claude binary. Smoke test
# is purely installer protocol.
#
# Usage: ./tests/smoke.sh

set -e

REPO_RESTART="$(cd "$(dirname "$0")/.." && pwd)"
REPO_HANDOFF="${REPO_HANDOFF:-$(cd "$REPO_RESTART/../claude-session-handoff" && pwd)}"

[ -x "$REPO_HANDOFF/install.sh" ] || { echo "FAIL: handoff installer not found at $REPO_HANDOFF"; exit 1; }
[ -x "$REPO_RESTART/install.sh" ] || { echo "FAIL: claude-restart installer not found at $REPO_RESTART"; exit 1; }

SANDBOX_BASE=$(mktemp -d /tmp/cl-smoke.XXXXXX)
trap 'rm -rf "$SANDBOX_BASE"' EXIT

PASS=0
FAIL=0

# --- helpers ---

new_sandbox() {
  SB="$SANDBOX_BASE/$1"
  rm -rf "$SB"
  mkdir -p "$SB/claude"
  : > "$SB/zshrc"
  CLAUDE_DIR="$SB/claude"
  RC_FILE="$SB/zshrc"
  export CLAUDE_DIR RC_FILE_OVERRIDE="$RC_FILE" SHELL_NAME_OVERRIDE=zsh
}

run_handoff()  { ( cd "$REPO_HANDOFF"  && ./install.sh "$@" ) >/dev/null; }
run_restart()  { ( cd "$REPO_RESTART"  && ./install.sh "$@" ) >/dev/null; }

assert() {
  DESC="$1"; shift
  if eval "$@"; then
    echo "  PASS  $DESC"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $DESC"
    FAIL=$((FAIL+1))
  fi
}

registered_by() {
  awk '/^# claude-wrapper: start/{f=1;next}/^# claude-wrapper: end/{f=0}f && /^# registered-by:/{sub(/^# registered-by:[[:space:]]*/,"");print;exit}' "$1"
}

block_present() { grep -q "^# claude-wrapper: start" "$1" 2>/dev/null; }

# --- Case 1: install handoff then restart ---
echo "Case 1: handoff then restart"
new_sandbox case1
run_handoff
run_restart
assert "shared block present"            'block_present "$RC_FILE"'
assert "wrapper file exists"             '[ -f "$CLAUDE_DIR/scripts/claude-wrapper.sh" ]'
assert "registered-by contains handoff"  '[ "$(registered_by "$RC_FILE" | grep -c claude-session-handoff)" -eq 1 ]'
assert "registered-by contains restart"  '[ "$(registered_by "$RC_FILE" | grep -c claude-restart)" -eq 1 ]'
assert "SessionStart handoff hook"       'grep -q handoff-session-start.sh "$CLAUDE_DIR/settings.json"'
assert "SessionStart capture hook"       'grep -q capture-session-id.sh "$CLAUDE_DIR/settings.json"'
assert "UserPromptSubmit handoff hook"   'grep -q handoff-prompt-hook.sh "$CLAUDE_DIR/settings.json"'
assert "UserPromptSubmit restart hook"   'grep -q restart-hook.sh "$CLAUDE_DIR/settings.json"'

# --- Case 2: reverse order ---
echo "Case 2: restart then handoff"
new_sandbox case2
run_restart
run_handoff
assert "registered-by contains both"     '[ "$(registered_by "$RC_FILE" | wc -w)" -eq 2 ]'
assert "single shared block"             '[ "$(grep -c "^# claude-wrapper: start" "$RC_FILE")" -eq 1 ]'

# --- Case 3: uninstall one keeps the other ---
echo "Case 3: uninstall handoff, restart still registered"
run_handoff --uninstall
assert "block still present"             'block_present "$RC_FILE"'
assert "only restart registered"         '[ "$(registered_by "$RC_FILE")" = "claude-restart" ]'
assert "wrapper kept"                    '[ -f "$CLAUDE_DIR/scripts/claude-wrapper.sh" ]'
assert "handoff hook gone"               '! grep -q handoff-prompt-hook.sh "$CLAUDE_DIR/settings.json"'
assert "restart hook still there"        'grep -q restart-hook.sh "$CLAUDE_DIR/settings.json"'

# --- Case 4: uninstall both ---
echo "Case 4: uninstall the rest"
run_restart --uninstall
assert "block removed"                   '! block_present "$RC_FILE"'
assert "wrapper removed"                 '[ ! -f "$CLAUDE_DIR/scripts/claude-wrapper.sh" ]'

# --- Case 5: legacy migration ---
echo "Case 5: legacy claude-restart block migration"
new_sandbox case5
cat > "$RC_FILE" << 'EOF'
# user content above

# claude-restart: start
claude() {
  ~/.claude/scripts/claude-wrapper.sh "$@"
}
# claude-restart: end

# user content below
EOF
run_handoff
assert "legacy block removed"            '! grep -q "^# claude-restart: start" "$RC_FILE"'
assert "shared block present"            'block_present "$RC_FILE"'
assert "restart preserved in registered-by" 'echo " $(registered_by "$RC_FILE") " | grep -q " claude-restart "'
assert "handoff added in registered-by"  'echo " $(registered_by "$RC_FILE") " | grep -q " claude-session-handoff "'

# --- Case 6: version comparison ---
echo "Case 6: lower-version installer keeps higher-version wrapper"
new_sandbox case6
run_handoff
# Bump version on installed wrapper to v99 to simulate a newer wrapper already present.
sed -i.bak 's/^# claude-wrapper version: .*/# claude-wrapper version: 99/' "$CLAUDE_DIR/scripts/claude-wrapper.sh"
rm -f "$CLAUDE_DIR/scripts/claude-wrapper.sh.bak"
run_restart
INSTALLED_VERSION=$(awk '/^# claude-wrapper version:/{print $4;exit}' "$CLAUDE_DIR/scripts/claude-wrapper.sh")
assert "wrapper kept at v99 (not downgraded)" '[ "$INSTALLED_VERSION" = "99" ]'

echo ""
echo "Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
