#!/bin/sh
# claude-restart installer.
# Installs the /restart command for Claude Code and (if needed) the
# shared claude-wrapper.sh that both claude-restart and
# claude-session-handoff coordinate through.
#
# Usage:
#   ./install.sh              Install
#   ./install.sh --uninstall  Remove all claude-restart changes
#
# Env vars (for sandbox testing):
#   CLAUDE_DIR          Override ~/.claude
#   RC_FILE_OVERRIDE    Force a specific shell rc file
#   SHELL_NAME_OVERRIDE Force shell detection (zsh|bash|fish)
#
# Shared wrapper protocol — see scripts/claude-wrapper.sh.
# Both installers:
#   1. Compare their bundled wrapper version against the installed one and
#      overwrite only if their version is higher (idempotent, latest-wins).
#   2. Maintain a single shell-function block in the user's rc file,
#      marked by `# claude-wrapper: start/end`, with a `# registered-by:`
#      line listing every tool that needs the wrapper. Install adds the
#      tool's name; uninstall removes it (and the entire block when empty).
#   3. Migrate legacy per-tool blocks (`# claude-restart: start`,
#      `# claude-session-handoff: start`) into the shared block.
#
# Supports: zsh, bash, fish.

set -e

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
COMMANDS_DIR="$CLAUDE_DIR/commands"
TMP_DIR="$CLAUDE_DIR/tmp"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

WRAPPER_PATH="$SCRIPTS_DIR/claude-wrapper.sh"
TOOL_NAME="claude-restart"
LEGACY_MARKER_START="# claude-restart: start"
LEGACY_MARKER_END="# claude-restart: end"
SHARED_MARKER_START="# claude-wrapper: start"
SHARED_MARKER_END="# claude-wrapper: end"

info() { echo "  [+] $1"; }
warn() { echo "  [!] $1"; }
error() { echo "  [x] $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Uninstall needs jq too — it rewrites settings.json — but must not demand
# `claude`, which may well be gone by the time someone uninstalls.
check_jq() {
  command -v jq >/dev/null 2>&1 || error "jq is required. Install: brew install jq (macOS) or apt install jq (Linux)"
}

check_deps() {
  check_jq
  command -v claude >/dev/null 2>&1 || error "claude is not installed or not in PATH. Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code"
}

detect_shell() {
  SHELL_NAME="${SHELL_NAME_OVERRIDE:-$(basename "$SHELL")}"
  if [ -n "$RC_FILE_OVERRIDE" ]; then
    RC_FILE="$RC_FILE_OVERRIDE"
    return
  fi
  case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    fish) RC_FILE="$HOME/.config/fish/functions/claude.fish" ;;
    *)    warn "Unsupported shell: $SHELL_NAME. Configure the wrapper manually."
          RC_FILE="" ;;
  esac
}

# --- Atomic file installation ---

# Install SRC at DST by writing a sibling temp file and renaming it into place.
# Args: $1 = source, $2 = destination, $3 = optional chmod mode.
#
# `cp` onto DST truncates and rewrites DST's EXISTING inode. A POSIX shell reads
# a script incrementally, and claude-wrapper.sh blocks inside `run_claude "$@"`
# for the whole session with its dispatch loop still unread — so overwriting it
# in place makes that shell resume at a byte offset that now points into
# different content, in the process that owns the user's terminal. Renaming
# swaps the directory entry to a NEW inode instead; the running shell keeps its
# open file description on the old one and finishes cleanly.
#
# The temp file must be a sibling of DST: `mv` is atomic only within a
# filesystem, and across one it degrades to copy-and-unlink.
#
# Part of the shared wrapper protocol: claude-session-handoff's installer writes
# the same file the same way, and covers it there with
# tests/wrapper-atomic-install.sh.
atomic_install() {
  SRC="$1"; DST="$2"; MODE="${3:-}"
  DST_TMP="$DST.new.$$"
  cp "$SRC" "$DST_TMP"
  if [ -n "$MODE" ]; then
    chmod "$MODE" "$DST_TMP"
  fi
  mv "$DST_TMP" "$DST"
}

# --- Shared wrapper management ---

wrapper_version_of() {
  if [ ! -f "$1" ]; then
    echo 0
    return
  fi
  V=$(awk '/^# claude-wrapper version:/ { print $4; exit }' "$1" 2>/dev/null)
  case "$V" in
    ''|*[!0-9]*) echo 0 ;;
    *)           echo "$V" ;;
  esac
}

install_wrapper() {
  OURS=$(wrapper_version_of "$SCRIPT_DIR/scripts/claude-wrapper.sh")
  THEIRS=$(wrapper_version_of "$WRAPPER_PATH")
  if [ "$OURS" -gt "$THEIRS" ]; then
    atomic_install "$SCRIPT_DIR/scripts/claude-wrapper.sh" "$WRAPPER_PATH" 755
    if [ "$THEIRS" -eq 0 ]; then
      info "Shared wrapper installed (v$OURS)"
    else
      info "Shared wrapper upgraded v$THEIRS -> v$OURS"
    fi
  else
    info "Shared wrapper already at v$THEIRS (>= our v$OURS, kept)"
  fi
}

# --- Shared rc block management (zsh/bash) ---

# True when every start marker in $1 is closed by a later end marker.
# Args: $1 = file, $2 = start marker, $3 = end marker.
#
# A sed range whose closing address never matches runs to end of file, so
# `sed "\|START|,\|END|d"` on an rc file with one hand-dropped end marker
# deleted every line below it — no backup, and a success message on the way out.
block_is_terminated() {
  awk -v s="$2" -v e="$3" '
    !inblock && index($0, s) { inblock=1; next }
    inblock && index($0, e) { inblock=0 }
    END { exit inblock }
  ' "$1"
}

# Print $1 with every $2..$3 marker block removed. Callers must have checked
# block_is_terminated first; an unterminated block swallows the rest of the file.
delete_marked_block() {
  awk -v s="$2" -v e="$3" '
    !inblock && index($0, s) { inblock=1; next }
    inblock { if (index($0, e)) inblock=0; next }
    { print }
  ' "$1"
}

# Replace rc file $1 with the output of the command in the remaining args,
# keeping a .bak of what it replaced (only ever the state before the most
# recent rewrite — a second run overwrites it).
#
# The filter's status is checked with `if`, not `&&`: `set -e` does not fire on
# a failed AND-list, so `filter > tmp && mv` leaves the caller free to print a
# success message after having written nothing.
#
# Writes THROUGH the rc file rather than renaming over it — a dotfiles-managed
# rc is usually a symlink, and `mv` would orphan the target and drop its mode.
rc_rewrite() {
  RC="$1"; shift
  TMP="${RC}.tmp"
  if "$@" > "$TMP"; then
    cp "$RC" "$RC.bak"
    cat "$TMP" > "$RC"
    rm -f "$TMP"
  else
    rm -f "$TMP"
    error "Failed to rewrite $RC — left untouched"
  fi
}

migrate_legacy_block() {
  RC="$1"; LMS="$2"; LME="$3"; TOOL="$4"
  [ -f "$RC" ] || return 0
  grep -q "$LMS" "$RC" 2>/dev/null || return 0
  if ! block_is_terminated "$RC" "$LMS" "$LME"; then
    warn "Unterminated block ($LMS) in $RC — left untouched. Add the '$LME' line by hand, then re-run."
    return 0
  fi
  rc_rewrite "$RC" delete_marked_block "$RC" "$LMS" "$LME"
  info "Migrated legacy block ($LMS) from $RC"
  rc_block_register "$RC" "$TOOL"
}

rc_block_register() {
  RC="$1"; TOOL="$2"
  [ -n "$RC" ] || return 0
  touch "$RC"

  if ! grep -q "$SHARED_MARKER_START" "$RC" 2>/dev/null; then
    cat >> "$RC" << SHARED_BLOCK

$SHARED_MARKER_START
# registered-by: $TOOL
# Shared wrapper for claude-restart and claude-session-handoff.
# See: https://github.com/yacb2/claude-restart
# See: https://github.com/user/claude-session-handoff
claude() {
  ~/.claude/scripts/claude-wrapper.sh "\$@"
}
$SHARED_MARKER_END
SHARED_BLOCK
    info "Shared wrapper block added to $RC (registered: $TOOL)"
    return
  fi

  REG_LINE=$(awk -v s="$SHARED_MARKER_START" -v e="$SHARED_MARKER_END" '
    $0 ~ s { inblock=1; next }
    $0 ~ e { inblock=0 }
    inblock && /^# registered-by:/ { print; exit }
  ' "$RC")
  case " $REG_LINE " in
    *" $TOOL "*)
      info "Already registered as '$TOOL' in $RC (skipped)"
      return
      ;;
  esac
  rc_rewrite "$RC" awk -v s="$SHARED_MARKER_START" -v e="$SHARED_MARKER_END" -v tool="$TOOL" '
    $0 ~ s { inblock=1; print; next }
    $0 ~ e { inblock=0; print; next }
    inblock && /^# registered-by:/ {
      sub(/\r?$/, " " tool); print; next
    }
    { print }
  ' "$RC"
  info "Registered '$TOOL' in shared block at $RC"
}

rc_block_unregister() {
  RC="$1"; TOOL="$2"
  [ -n "$RC" ] || return 0
  [ -f "$RC" ] || return 0
  grep -q "$SHARED_MARKER_START" "$RC" 2>/dev/null || return 0

  REG_LINE=$(awk -v s="$SHARED_MARKER_START" -v e="$SHARED_MARKER_END" '
    $0 ~ s { inblock=1; next }
    $0 ~ e { inblock=0 }
    inblock && /^# registered-by:/ { print; exit }
  ' "$RC")
  TOKENS=$(echo "$REG_LINE" | sed 's/^# registered-by:[[:space:]]*//')
  NEW_TOKENS=""
  for t in $TOKENS; do
    [ "$t" = "$TOOL" ] && continue
    if [ -z "$NEW_TOKENS" ]; then NEW_TOKENS="$t"; else NEW_TOKENS="$NEW_TOKENS $t"; fi
  done

  if [ -z "$NEW_TOKENS" ]; then
    if ! block_is_terminated "$RC" "$SHARED_MARKER_START" "$SHARED_MARKER_END"; then
      warn "Unterminated shared block in $RC — left untouched. Remove it by hand."
      return 0
    fi
    rc_rewrite "$RC" delete_marked_block "$RC" "$SHARED_MARKER_START" "$SHARED_MARKER_END"
    info "Removed shared wrapper block from $RC (no tools remain)"
  else
    rc_rewrite "$RC" awk -v s="$SHARED_MARKER_START" -v e="$SHARED_MARKER_END" -v new="$NEW_TOKENS" '
      $0 ~ s { inblock=1; print; next }
      $0 ~ e { inblock=0; print; next }
      inblock && /^# registered-by:/ { print "# registered-by: " new; next }
      { print }
    ' "$RC"
    info "Unregistered '$TOOL' from shared block at $RC (still registered: $NEW_TOKENS)"
  fi
}

# --- Fish equivalents ---

fish_register() {
  FISH_DIR="$HOME/.config/fish/functions"
  FISH_FILE="$FISH_DIR/claude.fish"
  mkdir -p "$FISH_DIR"

  if [ -f "$FISH_FILE" ] && grep -q "$SHARED_MARKER_START" "$FISH_FILE" 2>/dev/null; then
    REG_LINE=$(grep '^# registered-by:' "$FISH_FILE" | head -1)
    case " $REG_LINE " in
      *" $TOOL_NAME "*) info "Fish function already registers '$TOOL_NAME' (skipped)"; return ;;
    esac
    TMP="${FISH_FILE}.tmp"
    awk -v tool="$TOOL_NAME" '
      /^# registered-by:/ { sub(/\r?$/, " " tool); print; next }
      { print }
    ' "$FISH_FILE" > "$TMP" && mv "$TMP" "$FISH_FILE"
    info "Registered '$TOOL_NAME' in fish claude.fish"
    return
  fi

  if [ -f "$FISH_FILE" ]; then
    if grep -q "claude-restart\|claude-session-handoff" "$FISH_FILE" 2>/dev/null; then
      info "Migrating legacy fish claude.fish"
    else
      cp "$FISH_FILE" "$FISH_FILE.backup"
      warn "Existing claude.fish backed up to claude.fish.backup"
    fi
  fi

  cat > "$FISH_FILE" << FISH_FUNC
$SHARED_MARKER_START
# registered-by: $TOOL_NAME
# Shared wrapper for claude-restart and claude-session-handoff.
function claude
  ~/.claude/scripts/claude-wrapper.sh \$argv
end
$SHARED_MARKER_END
FISH_FUNC
  info "Fish function installed with '$TOOL_NAME' registered"
}

fish_unregister() {
  FISH_FILE="$HOME/.config/fish/functions/claude.fish"
  [ -f "$FISH_FILE" ] || return 0
  grep -q "$SHARED_MARKER_START" "$FISH_FILE" 2>/dev/null || return 0

  REG_LINE=$(grep '^# registered-by:' "$FISH_FILE" | head -1)
  TOKENS=$(echo "$REG_LINE" | sed 's/^# registered-by:[[:space:]]*//')
  NEW_TOKENS=""
  for t in $TOKENS; do
    [ "$t" = "$TOOL_NAME" ] && continue
    if [ -z "$NEW_TOKENS" ]; then NEW_TOKENS="$t"; else NEW_TOKENS="$NEW_TOKENS $t"; fi
  done

  if [ -z "$NEW_TOKENS" ]; then
    rm -f "$FISH_FILE"
    if [ -f "$FISH_FILE.backup" ]; then
      mv "$FISH_FILE.backup" "$FISH_FILE"
      info "Fish function removed (previous claude.fish restored from backup)"
    else
      info "Fish function removed"
    fi
  else
    TMP="${FISH_FILE}.tmp"
    awk -v new="$NEW_TOKENS" '
      /^# registered-by:/ { print "# registered-by: " new; next }
      { print }
    ' "$FISH_FILE" > "$TMP" && mv "$TMP" "$FISH_FILE"
    info "Unregistered '$TOOL_NAME' from fish claude.fish (still: $NEW_TOKENS)"
  fi
}

# --- settings.json hook helpers ---

# Guarantee SETTINGS_FILE holds a JSON object before anything mutates it.
#
# Seeding only when the file was ABSENT was not enough: on empty input
# `jq '. + {…}'` exits 0 with empty output, so the result was moved into place
# and a 0-byte settings.json reported as a successful install. An exit-code
# check does not catch that one — jq genuinely succeeded.
#
# Only jq's exit 4 (no output produced at all) means the file is empty or
# whitespace and safe to seed. Exit 5 is a parse error and exit 1 is valid JSON
# of the wrong type; both are real content, and writing `{}` over either would
# destroy more than the bug ever did.
ensure_settings() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    printf '{}\n' > "$SETTINGS_FILE"
    return
  fi
  STATUS=0
  jq -e 'type == "object"' "$SETTINGS_FILE" >/dev/null 2>&1 || STATUS=$?
  case "$STATUS" in
    0) ;;
    4) printf '{}\n' > "$SETTINGS_FILE" ;;
    *) error "$SETTINGS_FILE is not a JSON object — fix it by hand, then re-run" ;;
  esac
}

# Run a jq program over SETTINGS_FILE and install the result, or abort.
#
# `jq … > "$TMP" && mv …` looks safe but is not: `set -e` does not fire on a
# failed AND-list, so a jq that could not parse settings.json left the caller
# free to print `[+] … hook added` and `Done!` over a file it never wrote.
settings_apply() {
  TMP="${SETTINGS_FILE}.tmp"
  if jq "$@" "$SETTINGS_FILE" > "$TMP"; then
    mv "$TMP" "$SETTINGS_FILE"
  else
    rm -f "$TMP"
    error "Failed to update $SETTINGS_FILE — left untouched"
  fi
}

add_hook() {
  EVENT="$1"; CMD="$2"
  ensure_settings
  if grep -q "$CMD" "$SETTINGS_FILE"; then
    info "$EVENT hook '$CMD' already configured (skipped)"
    return
  fi
  if jq -e ".hooks.$EVENT" "$SETTINGS_FILE" >/dev/null 2>&1; then
    settings_apply --arg cmd "$CMD" --arg ev "$EVENT" '.hooks[$ev] += [{"hooks":[{"type":"command","command":$cmd}]}]'
  elif jq -e '.hooks' "$SETTINGS_FILE" >/dev/null 2>&1; then
    settings_apply --arg cmd "$CMD" --arg ev "$EVENT" '.hooks[$ev] = [{"hooks":[{"type":"command","command":$cmd}]}]'
  else
    settings_apply --arg cmd "$CMD" --arg ev "$EVENT" '. + {"hooks": {($ev): [{"hooks":[{"type":"command","command":$cmd}]}]}}'
  fi
  info "$EVENT hook '$CMD' added"
}

remove_hook() {
  EVENT="$1"; CMD="$2"
  [ -f "$SETTINGS_FILE" ] || return 0
  grep -q "$CMD" "$SETTINGS_FILE" || return 0
  # Filter the INNER hook array, then drop groups that became empty. Selecting
  # over the outer array instead takes the whole matcher group down as soon as
  # one hook inside it matches — including hooks the user put there themselves.
  settings_apply --arg cmd "$CMD" --arg ev "$EVENT" '
    if .hooks[$ev] then
      .hooks[$ev] |= (
        map(.hooks |= map(select(.command != $cmd)))
        | map(select(.hooks | length > 0))
      )
      | if .hooks[$ev] == [] then del(.hooks[$ev]) else . end
    else . end
  '
  info "$EVENT hook '$CMD' removed"
}

# --- Install / Uninstall ---

install() {
  check_deps
  detect_shell

  echo ""
  echo "  Installing claude-restart..."
  echo ""

  mkdir -p "$SCRIPTS_DIR" "$COMMANDS_DIR" "$TMP_DIR"
  info "Directories ready"

  install_wrapper

  atomic_install "$SCRIPT_DIR/scripts/capture-session-id.sh" "$SCRIPTS_DIR/capture-session-id.sh" 755
  atomic_install "$SCRIPT_DIR/scripts/restart-hook.sh" "$SCRIPTS_DIR/restart-hook.sh" 755
  info "Restart hook scripts installed"

  atomic_install "$SCRIPT_DIR/commands/restart.md" "$COMMANDS_DIR/restart.md"
  info "Slash command /restart installed"

  if [ -n "$RC_FILE" ]; then
    if [ "$SHELL_NAME" = "fish" ]; then
      fish_register
    else
      migrate_legacy_block "$RC_FILE" "$LEGACY_MARKER_START" "$LEGACY_MARKER_END" "$TOOL_NAME"
      migrate_legacy_block "$RC_FILE" "# claude-session-handoff: start" "# claude-session-handoff: end" "claude-session-handoff"
      rc_block_register "$RC_FILE" "$TOOL_NAME"
    fi
  fi

  add_hook SessionStart "~/.claude/scripts/capture-session-id.sh"
  add_hook UserPromptSubmit "~/.claude/scripts/restart-hook.sh"

  echo ""
  echo "  Done! Open a new terminal and run 'claude' to start."
  echo "  Use /restart inside Claude Code to restart the session."
  echo ""
}

uninstall() {
  # Before anything is deleted: without jq the settings.json rewrites below
  # cannot happen, and uninstall would report both hooks removed while leaving
  # them registered against scripts it had just deleted.
  check_jq
  detect_shell

  echo ""
  echo "  Uninstalling claude-restart..."
  echo ""

  rm -f "$SCRIPTS_DIR/capture-session-id.sh" "$SCRIPTS_DIR/restart-hook.sh"
  info "Restart hook scripts removed"

  rm -f "$COMMANDS_DIR/restart.md"
  info "Slash command removed"

  rm -f "$TMP_DIR"/restart-flag-* "$TMP_DIR"/session-id-*
  info "Temp files cleaned"

  if [ -n "$RC_FILE" ]; then
    if [ "$SHELL_NAME" = "fish" ]; then
      fish_unregister
    else
      rc_block_unregister "$RC_FILE" "$TOOL_NAME"
    fi
  fi

  remove_hook SessionStart "~/.claude/scripts/capture-session-id.sh"
  remove_hook UserPromptSubmit "~/.claude/scripts/restart-hook.sh"

  if [ -f "$WRAPPER_PATH" ] && [ -n "$RC_FILE" ] && [ -f "$RC_FILE" ]; then
    if ! grep -q "$SHARED_MARKER_START" "$RC_FILE" 2>/dev/null; then
      rm -f "$WRAPPER_PATH"
      info "Shared wrapper removed (no tools left)"
    else
      info "Shared wrapper kept (other tools still registered)"
    fi
  fi

  echo ""
  echo "  Done! claude-restart has been removed."
  echo ""
}

case "${1:-}" in
  --uninstall|-u) uninstall ;;
  --help|-h)
    echo "Usage: $0 [--uninstall]"
    echo ""
    echo "  Install or uninstall the /restart command for Claude Code."
    echo ""
    echo "Options:"
    echo "  --uninstall, -u   Remove all claude-restart files and configuration"
    echo "  --help, -h        Show this help message"
    ;;
  "") install ;;
  *) error "Unknown option: $1. Use --help for usage." ;;
esac
