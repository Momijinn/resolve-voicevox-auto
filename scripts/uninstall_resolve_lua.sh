#!/usr/bin/env zsh
set -euo pipefail

DEFAULT_TARGET="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/resolve_voicevox_auto"
TARGET_DIR="${1:-${RESOLVE_SCRIPTS_TARGET_DIR:-$DEFAULT_TARGET}}"

FORCE=0
if [[ "${2:-}" == "--force" || "${1:-}" == "--force" ]]; then
  FORCE=1
fi

if [[ ! -e "$TARGET_DIR" ]]; then
  echo "target not found, nothing to uninstall: $TARGET_DIR"
  exit 0
fi

if [[ $FORCE -eq 0 && "${TARGET_DIR:t}" != "resolve_voicevox_auto" ]]; then
  echo "refusing to remove non-standard target: $TARGET_DIR" >&2
  echo "If this is intended, run with --force" >&2
  exit 1
fi

rm -rf "$TARGET_DIR"

echo "Uninstalled Resolve Lua scripts."
echo "- Removed: $TARGET_DIR"
