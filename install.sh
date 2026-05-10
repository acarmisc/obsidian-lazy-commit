#!/bin/bash
set -euo pipefail

if ! command -v afm-cli &>/dev/null; then
  echo "[install] Installing afm-cli..."
  brew tap CreevekCZ/tap
  brew install afm-cli
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$SCRIPT_DIR/com.user.obsidian-lazy-commit.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist"
CONFIG_DIR="$HOME/.config/obsidian-lazy-commit"
CONFIG_FILE="$CONFIG_DIR/config"

mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<EOF
# Path to the git repo to commit into
REPO_DIR=$SCRIPT_DIR
# Optional: path to watch for changes (defaults to REPO_DIR)
# VAULT_DIR=/path/to/obsidian/vault
EOF
  echo "[install] Created default config at $CONFIG_FILE"
fi

cp "$PLIST_SRC" "$PLIST_DST"
echo "[install] Installed plist to $PLIST_DST"

launchctl load "$PLIST_DST" 2>/dev/null || launchctl bootstrap gui/$(id -u) "$PLIST_DST"
echo "[install] Loaded launchd job: com.user.obsidian-lazy-commit"

echo "[install] Done. Job runs every 60 minutes. Logs: /tmp/obsidian-lazy-commit.{log,err}"
