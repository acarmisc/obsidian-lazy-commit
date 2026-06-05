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
  read -p "Enter the path to your Obsidian vault (default: $SCRIPT_DIR): " VAULT_DIR_INPUT
  VAULT_DIR_INPUT="${VAULT_DIR_INPUT:-$SCRIPT_DIR}"
  REPO_DIR_ABS="$(cd "$VAULT_DIR_INPUT" && pwd)"
  
  cat > "$CONFIG_FILE" <<EOF
# Path to the Obsidian vault (or any folder) to watch and commit
VAULT_DIR=$REPO_DIR_ABS
EOF
  echo "[install] Created config at $CONFIG_FILE with VAULT_DIR=$REPO_DIR_ABS"
else
  read -p "Enter the path to your Obsidian vault (current: $(source "$CONFIG_FILE" && echo "${VAULT_DIR:-$REPO_DIR}")): " VAULT_DIR_INPUT
  VAULT_DIR_INPUT="${VAULT_DIR_INPUT:-$(source "$CONFIG_FILE" && echo "${VAULT_DIR:-$REPO_DIR}")}"
  REPO_DIR_ABS="$(cd "$VAULT_DIR_INPUT" && pwd)"
  sed -i.bak "s|^VAULT_DIR=.*|VAULT_DIR=$REPO_DIR_ABS|g" "$CONFIG_FILE"
  echo "[install] Updated config at $CONFIG_FILE with VAULT_DIR=$REPO_DIR_ABS"
fi

cp "$PLIST_SRC" "$PLIST_DST"
sed -i.bak "s|<string>/Users/andrea/Documents/acarmisc/</string>|<string>$REPO_DIR_ABS</string>|g" "$PLIST_DST"
echo "[install] Installed plist to $PLIST_DST with REPO_DIR=$REPO_DIR_ABS"

launchctl load "$PLIST_DST" 2>/dev/null || launchctl bootstrap gui/$(id -u) "$PLIST_DST"
echo "[install] Loaded launchd job: com.user.obsidian-lazy-commit"

echo "[install] Done. Job runs every 60 minutes. Logs: /tmp/obsidian-lazy-commit.{log,err}"
