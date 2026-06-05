#!/bin/bash
set -euo pipefail

: "${REPO_DIR:=$(cd "$(dirname "$0")" && pwd)}"
: "${VAULT_DIR:=$REPO_DIR}"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

CONFIG_FILE="$HOME/.config/obsidian-lazy-commit/config"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

: "${VAULT_DIR:=$REPO_DIR}"

if [ ! -d "$VAULT_DIR" ]; then
  log "ERROR: VAULT_DIR '$VAULT_DIR' does not exist. Check config."
  exit 1
fi

cd "$VAULT_DIR"

log "Started"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "ERROR: '$VAULT_DIR' is not a git working tree. Run install.sh or 'git init' here."
  exit 1
fi

if ! CHANGES=$(git status --porcelain 2>/dev/null); then
  log "ERROR: 'git status' failed in '$VAULT_DIR'."
  exit 1
fi
if [ -z "$CHANGES" ]; then
  log "No changes, skipping."
  exit 0
fi

git add -A

DIFF=$(git diff --cached)
DIFF="${DIFF:0:2000}"
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

PUSH_OUTPUT=$(git push 2>&1) || PUSH_RC=$?
echo "$PUSH_OUTPUT" >> /tmp/obsidian-lazy-commit.log
if [ "${PUSH_RC:-0}" -eq 0 ]; then
  log "Pushed successfully"
else
  log "WARNING: Push failed (rc=${PUSH_RC}). Check remote/auth in the log above."
fi

log "Completed"
