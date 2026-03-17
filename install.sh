#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${SHOW_CODEX_USAGE_REPO_OWNER:-nick-ma}"
REPO_NAME="${SHOW_CODEX_USAGE_REPO_NAME:-show-codex-usage}"
REPO_BRANCH="${SHOW_CODEX_USAGE_REPO_BRANCH:-main}"
SCRIPT_NAME="${SHOW_CODEX_USAGE_SCRIPT_NAME:-show_codex_usage.sh}"
COMMAND_NAME="${SHOW_CODEX_USAGE_COMMAND_NAME:-show-codex-usage}"
ALIAS_NAME="${SHOW_CODEX_USAGE_ALIAS:-scu}"
INSTALL_DIR="${SHOW_CODEX_USAGE_INSTALL_DIR:-$HOME/.local/bin}"
TARGET_PATH="${INSTALL_DIR}/${COMMAND_NAME}"
RC_FILE_OVERRIDE="${SHOW_CODEX_USAGE_RC_FILE:-}"
SOURCE_URL="${SHOW_CODEX_USAGE_SOURCE_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/${SCRIPT_NAME}}"
RC_MARKER_START="# >>> show-codex-usage >>>"
RC_MARKER_END="# <<< show-codex-usage <<<"

require_command() {
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: ${cmd} is required but not installed." >&2
    exit 1
  fi
}

detect_rc_file() {
  if [[ -n "$RC_FILE_OVERRIDE" ]]; then
    printf '%s\n' "$RC_FILE_OVERRIDE"
    return 0
  fi

  case "$(basename "${SHELL:-}")" in
    zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    bash)
      if [[ -f "$HOME/.bashrc" || ! -f "$HOME/.bash_profile" ]]; then
        printf '%s\n' "$HOME/.bashrc"
      else
        printf '%s\n' "$HOME/.bash_profile"
      fi
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

append_shell_block() {
  local rc_file="$1"
  local rc_dir

  rc_dir="$(dirname "$rc_file")"
  mkdir -p "$rc_dir"
  touch "$rc_file"

  if grep -Fq "$RC_MARKER_START" "$rc_file"; then
    return 0
  fi

  cat >>"$rc_file" <<EOF

$RC_MARKER_START
case ":\$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) export PATH="$INSTALL_DIR:\$PATH" ;;
esac
alias $ALIAS_NAME='$COMMAND_NAME'
$RC_MARKER_END
EOF
}

main() {
  local rc_file

  require_command bash
  require_command curl

  mkdir -p "$INSTALL_DIR"

  curl -fsSL "$SOURCE_URL" -o "$TARGET_PATH"
  chmod +x "$TARGET_PATH"

  rc_file="$(detect_rc_file)"
  append_shell_block "$rc_file"

  cat <<EOF
Installed:
  $TARGET_PATH

Shell config updated:
  $rc_file

Next:
  source "$rc_file"
  $COMMAND_NAME
  $ALIAS_NAME
EOF
}

main "$@"
