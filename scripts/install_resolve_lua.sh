#!/usr/bin/env zsh
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"

DEFAULT_TARGET="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/resolve_voicevox_auto"
TARGET_DIR="${RESOLVE_SCRIPTS_TARGET_DIR:-$DEFAULT_TARGET}"
CONFIG_POLICY="keep"

print_usage() {
  cat <<EOF
Usage:
  ./scripts/install_resolve_lua.sh [TARGET_DIR] [--config-policy keep|push|pull]

Config policy:
  keep  : target の config.data を優先（存在しない時だけ workspace からコピー）
  push  : workspace(src/config.data) で target を常に上書き
  pull  : 先に target/config.data を workspace へ取り込み、その後 keep と同様に配置
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-policy)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --config-policy" >&2
        print_usage
        exit 1
      fi
      CONFIG_POLICY="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --*)
      echo "unknown option: $1" >&2
      print_usage
      exit 1
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

if [[ "$CONFIG_POLICY" != "keep" && "$CONFIG_POLICY" != "push" && "$CONFIG_POLICY" != "pull" ]]; then
  echo "invalid --config-policy: $CONFIG_POLICY (use keep|push|pull)" >&2
  exit 1
fi

if [[ ! -d "$SRC_DIR" ]]; then
  echo "source directory not found: $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

if [[ "$CONFIG_POLICY" == "pull" && -f "$TARGET_DIR/config.data" ]]; then
  cp "$TARGET_DIR/config.data" "$SRC_DIR/config.data"
  echo "pulled config.data from target: $SRC_DIR/config.data"
fi

cp "$SRC_DIR/config.lua" "$TARGET_DIR/config.lua"
cp "$SRC_DIR/watch_start.lua" "$TARGET_DIR/watch_start.lua"
cp "$SRC_DIR/watch_stop.lua" "$TARGET_DIR/watch_stop.lua"
cp "$SRC_DIR/one_shot.lua" "$TARGET_DIR/one_shot.lua"
if [[ -f "$TARGET_DIR/main.lua" ]]; then
  rm -f "$TARGET_DIR/main.lua"
  echo "removed legacy main.lua: $TARGET_DIR/main.lua"
fi
if [[ -f "$TARGET_DIR/auto_watch.lua" ]]; then
  rm -f "$TARGET_DIR/auto_watch.lua"
  echo "removed legacy auto_watch.lua: $TARGET_DIR/auto_watch.lua"
fi
if [[ -f "$TARGET_DIR/stop_watch.lua" ]]; then
  rm -f "$TARGET_DIR/stop_watch.lua"
  echo "removed legacy stop_watch.lua: $TARGET_DIR/stop_watch.lua"
fi
if [[ "$CONFIG_POLICY" == "push" ]]; then
  cp "$SRC_DIR/config.data" "$TARGET_DIR/config.data"
  echo "overwrote config.data from workspace: $TARGET_DIR/config.data"
elif [[ ! -f "$TARGET_DIR/config.data" ]]; then
  cp "$SRC_DIR/config.data" "$TARGET_DIR/config.data"
else
  echo "keep existing config.data: $TARGET_DIR/config.data"
fi
if [[ -f "$TARGET_DIR/config_gui.lua" ]]; then
  rm -f "$TARGET_DIR/config_gui.lua"
  echo "removed legacy config_gui.lua: $TARGET_DIR/config_gui.lua"
fi
cat <<EOF
Installed Resolve Lua scripts.
- Source: $SRC_DIR
- Target: $TARGET_DIR
- Config policy: $CONFIG_POLICY

Next:
1) Restart DaVinci Resolve (if already open)
2) Open Workspace > Scripts > Utility > resolve_voicevox_auto > config.lua (設定GUI)
3) Pseudo real-time: run watch_start.lua / stop with watch_stop.lua
4) One-shot: run one_shot.lua after saving settings
EOF
