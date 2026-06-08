#!/bin/bash
set -euo pipefail

PLIST_DST="$HOME/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist"

if launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null; then
  echo "[uninstall] Booted out launchd job com.user.obsidian-lazy-commit"
elif launchctl unload "$PLIST_DST" 2>/dev/null; then
  echo "[uninstall] Unloaded launchd job com.user.obsidian-lazy-commit"
else
  echo "[uninstall] launchd job was not loaded (skipping)"
fi

rm -f "$PLIST_DST"
echo "[uninstall] Removed $PLIST_DST"
echo "[uninstall] Config left in place: $HOME/.config/obsidian-lazy-commit/ (delete manually for a clean uninstall)"
echo "[uninstall] Logs left in place: /tmp/obsidian-lazy-commit.{log,err} (delete manually for a clean uninstall)"
