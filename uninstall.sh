#!/bin/bash
set -euo pipefail

PLIST_DST="$HOME/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist"

launchctl bootout gui/$(id -u) "$PLIST_DST" 2>/dev/null || launchctl unload "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST"
echo "[uninstall] Removed launchd job com.user.obsidian-lazy-commit"
