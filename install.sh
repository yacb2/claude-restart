#!/bin/sh
# claude-restart installer
# Installs the /restart command for Claude Code.
#
# Usage:
#   ./install.sh              Install
#   ./install.sh --uninstall  Remove all changes
#
# Supports: zsh, bash, fish

set -e

# --- Configuration ---
CLAUDE_DIR="$HOME/.claude"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
COMMANDS_DIR="$CLAUDE_DIR/commands"
TMP_DIR="$CLAUDE_DIR/tmp"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# Marker comments used to identify our additions
MARKER_START="# claude-restart: start"
MARKER_END="# claude-restart: end"

# --- Helpers ---
info() { echo "  [+] $1"; }
warn() { echo "  [!] $1"; }
error() { echo "  [x] $1" >&2; exit 1; }

# Detect the source directory (where install.sh lives)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Dependency check ---
check_deps() {
  if ! command -v jq >/dev/null 2>&1; then
    error "jq is required but not installed. Install it with: brew install jq (macOS) or apt install jq (Linux)"
  fi
  if ! command -v claude >/dev/null 2>&1; then
    error "claude is not installed or not in PATH. Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code"
  fi
}

# --- Shell detection ---
detect_shell() {
  SHELL_NAME=$(basename "$SHELL")
  case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    fish) RC_FILE="$HOME/.config/fish/functions/claude.fish" ;;
    *)    warn "Unsupported shell: $SHELL_NAME. You'll need to configure the wrapper manually."
          RC_FILE="" ;;
  esac
}

# --- Install ---
install() {
  check_deps
  detect_shell

  echo ""
  echo "  Installing claude-restart..."
  echo ""

  # 1. Create directories
  mkdir -p "$SCRIPTS_DIR" "$COMMANDS_DIR" "$TMP_DIR"
  info "Directories ready"

  # 2. Copy scripts
  cp "$SCRIPT_DIR/scripts/claude-wrapper.sh" "$SCRIPTS_DIR/claude-wrapper.sh"
  cp "$SCRIPT_DIR/scripts/capture-session-id.sh" "$SCRIPTS_DIR/capture-session-id.sh"
  chmod +x "$SCRIPTS_DIR/claude-wrapper.sh" "$SCRIPTS_DIR/capture-session-id.sh"
  info "Scripts installed"

  # 3. Copy command
  cp "$SCRIPT_DIR/commands/restart.md" "$COMMANDS_DIR/restart.md"
  info "Command /restart installed"

  # 4. Add shell function (idempotent)
  if [ -n "$RC_FILE" ]; then
    if [ "$SHELL_NAME" = "fish" ]; then
      install_fish
    else
      install_posix_shell
    fi
  fi

  # 5. Add SessionStart hook to settings.json
  install_hook

  echo ""
  echo "  Done! Open a new terminal and run 'claude' to start."
  echo "  Use /restart inside Claude Code to restart the session."
  echo ""
}

install_posix_shell() {
  # Check if already installed
  if [ -f "$RC_FILE" ] && grep -q "$MARKER_START" "$RC_FILE"; then
    info "Shell function already in $RC_FILE (skipped)"
    return
  fi

  cat >> "$RC_FILE" << 'SHELL_FUNC'

# claude-restart: start
# Wrapper that enables /restart inside Claude Code sessions.
# See: https://github.com/yacb2/claude-restart
claude() {
  ~/.claude/scripts/claude-wrapper.sh "$@"
}
# claude-restart: end
SHELL_FUNC

  info "Shell function added to $RC_FILE"
}

install_fish() {
  # Fish uses function files, not rc appending
  FISH_DIR="$HOME/.config/fish/functions"
  mkdir -p "$FISH_DIR"

  if [ -f "$FISH_DIR/claude.fish" ] && grep -q "claude-restart" "$FISH_DIR/claude.fish"; then
    info "Fish function already installed (skipped)"
    return
  fi

  cat > "$FISH_DIR/claude.fish" << 'FISH_FUNC'
# claude-restart: Wrapper that enables /restart inside Claude Code sessions.
# See: https://github.com/yacb2/claude-restart
function claude
  ~/.claude/scripts/claude-wrapper.sh $argv
end
FISH_FUNC

  info "Fish function installed at $FISH_DIR/claude.fish"
}

install_hook() {
  # If settings.json doesn't exist, create minimal one
  if [ ! -f "$SETTINGS_FILE" ]; then
    cat > "$SETTINGS_FILE" << 'SETTINGS'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/scripts/capture-session-id.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS
    info "Created settings.json with SessionStart hook"
    return
  fi

  # Check if hook already exists
  if grep -q "capture-session-id.sh" "$SETTINGS_FILE"; then
    info "SessionStart hook already configured (skipped)"
    return
  fi

  # Merge hook into existing settings.json using jq
  if jq -e '.hooks.SessionStart' "$SETTINGS_FILE" >/dev/null 2>&1; then
    # SessionStart array exists — append our hook
    TMP_SETTINGS="${SETTINGS_FILE}.tmp"
    jq '.hooks.SessionStart += [{"hooks": [{"type": "command", "command": "~/.claude/scripts/capture-session-id.sh"}]}]' \
      "$SETTINGS_FILE" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS_FILE"
    info "Appended hook to existing SessionStart array"
  elif jq -e '.hooks' "$SETTINGS_FILE" >/dev/null 2>&1; then
    # hooks object exists but no SessionStart — add it
    TMP_SETTINGS="${SETTINGS_FILE}.tmp"
    jq '.hooks.SessionStart = [{"hooks": [{"type": "command", "command": "~/.claude/scripts/capture-session-id.sh"}]}]' \
      "$SETTINGS_FILE" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS_FILE"
    info "Added SessionStart hook to existing hooks"
  else
    # No hooks object — add it
    TMP_SETTINGS="${SETTINGS_FILE}.tmp"
    jq '. + {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "~/.claude/scripts/capture-session-id.sh"}]}]}}' \
      "$SETTINGS_FILE" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS_FILE"
    info "Added hooks with SessionStart to settings.json"
  fi
}

# --- Uninstall ---
uninstall() {
  detect_shell

  echo ""
  echo "  Uninstalling claude-restart..."
  echo ""

  # 1. Remove scripts
  rm -f "$SCRIPTS_DIR/claude-wrapper.sh" "$SCRIPTS_DIR/capture-session-id.sh"
  info "Scripts removed"

  # 2. Remove command
  rm -f "$COMMANDS_DIR/restart.md"
  info "Command /restart removed"

  # 3. Remove tmp files
  rm -f "$TMP_DIR/restart-flag" "$TMP_DIR/session-id"
  info "Temp files cleaned"

  # 4. Remove shell function
  if [ -n "$RC_FILE" ] && [ -f "$RC_FILE" ]; then
    if [ "$SHELL_NAME" = "fish" ]; then
      if [ -f "$HOME/.config/fish/functions/claude.fish" ] && grep -q "claude-restart" "$HOME/.config/fish/functions/claude.fish"; then
        rm -f "$HOME/.config/fish/functions/claude.fish"
        info "Fish function removed"
      fi
    else
      if grep -q "$MARKER_START" "$RC_FILE"; then
        # Remove everything between markers (inclusive)
        TMP_RC="${RC_FILE}.tmp"
        sed "/$MARKER_START/,/$MARKER_END/d" "$RC_FILE" > "$TMP_RC" && mv "$TMP_RC" "$RC_FILE"
        info "Shell function removed from $RC_FILE"
      fi
    fi
  fi

  # 5. Remove SessionStart hook from settings.json
  if [ -f "$SETTINGS_FILE" ] && grep -q "capture-session-id.sh" "$SETTINGS_FILE"; then
    TMP_SETTINGS="${SETTINGS_FILE}.tmp"
    jq '
      if .hooks.SessionStart then
        .hooks.SessionStart |= map(select(.hooks | all(.command != "~/.claude/scripts/capture-session-id.sh")))
        | if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end
      else . end
    ' "$SETTINGS_FILE" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS_FILE"
    info "SessionStart hook removed from settings.json"
  fi

  echo ""
  echo "  Done! claude-restart has been removed."
  echo ""
}

# --- Main ---
case "${1:-}" in
  --uninstall|-u)
    uninstall
    ;;
  --help|-h)
    echo "Usage: $0 [--uninstall]"
    echo ""
    echo "  Install or uninstall the /restart command for Claude Code."
    echo ""
    echo "Options:"
    echo "  --uninstall, -u   Remove all claude-restart files and configuration"
    echo "  --help, -h        Show this help message"
    ;;
  "")
    install
    ;;
  *)
    error "Unknown option: $1. Use --help for usage."
    ;;
esac
