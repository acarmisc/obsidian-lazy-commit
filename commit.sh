#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

CONFIG_FILE="$HOME/.config/obsidian-lazy-commit/config"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

VAULT_DIR="${VAULT_DIR:-$REPO_DIR}"
cd "$REPO_DIR"

log "Started"

CHANGES=$(git status --porcelain 2>/dev/null)
if [ -z "$CHANGES" ]; then
  log "No changes, skipping."
  exit 0
fi

git add -A

DIFF=$(git diff --cached | head -c 2000)
if [ -z "$DIFF" ]; then
  log "Nothing staged after add, skipping."
  exit 0
fi

MSG=$(afm-cli -s "Generate a concise one-line git commit message (max 72 chars, no quotes). Summarize the diff." -p "$DIFF" 2>/dev/null || echo "auto-sync: $(date +%Y-%m-%d_%H:%M)")
MSG=$(echo "$MSG" | head -1 | cut -c1-72)

if git commit -m "$MSG"; then
  log "Committed: $MSG"
else
  log "ERROR: Commit failed"
  exit 1
fi

if git push 2>&1 | tee -a /tmp/obsidian-lazy-commit.log; then
  log "Pushed successfully"
else
  log "WARNING: Push failed (remote not configured?)"
fi

log "Completed"
