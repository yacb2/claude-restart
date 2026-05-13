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

check_deps() {
  command -v jq >/dev/null 2>&1 || error "jq is required. Install: brew install jq (macOS) or apt install jq (Linux)"
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
    cp "$SCRIPT_DIR/scripts/claude-wrapper.sh" "$WRAPPER_PATH"
    chmod +x "$WRAPPER_PATH"
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

migrate_legacy_block() {
  RC="$1"; LMS="$2"; LME="$3"; TOOL="$4"
  [ -f "$RC" ] || return 0
  grep -q "$LMS" "$RC" 2>/dev/null || return 0
  TMP="${RC}.tmp"
  sed "\|$LMS|,\|$LME|d" "$RC" > "$TMP" && mv "$TMP" "$RC"
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
# See: https://github.com/yoelacevedo/claude-session-handoff
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
  TMP="${RC}.tmp"
  awk -v s="$SHARED_MARKER_START" -v e="$SHARED_MARKER_END" -v tool="$TOOL" '
    $0 ~ s { inblock=1; print; next }
    $0 ~ e { inblock=0; print; next }
    inblock && /^# registered-by:/ {
      sub(/\r?$/, " " tool); print; next
    }
    { print }
  ' "$RC" > "$TMP" && mv "$TMP" "$RC"
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
    TMP="${RC}.tmp"
    sed "\|$SHARED_MARKER_START|,\|$SHARED_MARKER_END|d" "$RC" > "$TMP" && mv "$TMP" "$RC"
    info "Removed shared wrapper block from $RC (no tools remain)"
  else
    TMP="${RC}.tmp"
    awk -v s="$SHARED_MARKER_START" -v e="$SHARED_MARKER_END" -v new="$NEW_TOKENS" '
      $0 ~ s { inblock=1; print; next }
      $0 ~ e { inblock=0; print; next }
      inblock && /^# registered-by:/ { print "# registered-by: " new; next }
      { print }
    ' "$RC" > "$TMP" && mv "$TMP" "$RC"
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

ensure_settings() {
  [ -f "$SETTINGS_FILE" ] || printf '{}\n' > "$SETTINGS_FILE"
}

add_hook() {
  EVENT="$1"; CMD="$2"
  ensure_settings
  if grep -q "$CMD" "$SETTINGS_FILE"; then
    info "$EVENT hook '$CMD' already configured (skipped)"
    return
  fi
  TMP="${SETTINGS_FILE}.tmp"
  if jq -e ".hooks.$EVENT" "$SETTINGS_FILE" >/dev/null 2>&1; then
    jq --arg cmd "$CMD" --arg ev "$EVENT" '.hooks[$ev] += [{"hooks":[{"type":"command","command":$cmd}]}]' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
  elif jq -e '.hooks' "$SETTINGS_FILE" >/dev/null 2>&1; then
    jq --arg cmd "$CMD" --arg ev "$EVENT" '.hooks[$ev] = [{"hooks":[{"type":"command","command":$cmd}]}]' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
  else
    jq --arg cmd "$CMD" --arg ev "$EVENT" '. + {"hooks": {($ev): [{"hooks":[{"type":"command","command":$cmd}]}]}}' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
  fi
  info "$EVENT hook '$CMD' added"
}

remove_hook() {
  EVENT="$1"; CMD="$2"
  [ -f "$SETTINGS_FILE" ] || return 0
  grep -q "$CMD" "$SETTINGS_FILE" || return 0
  TMP="${SETTINGS_FILE}.tmp"
  jq --arg cmd "$CMD" --arg ev "$EVENT" '
    if .hooks[$ev] then
      .hooks[$ev] |= map(select(.hooks | all(.command != $cmd)))
      | if .hooks[$ev] == [] then del(.hooks[$ev]) else . end
    else . end
  ' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
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

  cp "$SCRIPT_DIR/scripts/capture-session-id.sh" "$SCRIPTS_DIR/capture-session-id.sh"
  cp "$SCRIPT_DIR/scripts/restart-hook.sh" "$SCRIPTS_DIR/restart-hook.sh"
  chmod +x "$SCRIPTS_DIR/capture-session-id.sh" "$SCRIPTS_DIR/restart-hook.sh"
  info "Restart hook scripts installed"

  cp "$SCRIPT_DIR/commands/restart.md" "$COMMANDS_DIR/restart.md"
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
