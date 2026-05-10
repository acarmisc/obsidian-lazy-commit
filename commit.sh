#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG_FILE="$HOME/.config/obsidian-lazy-commit/config"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

VAULT_DIR="${VAULT_DIR:-$REPO_DIR}"
cd "$REPO_DIR"

CHANGES=$(git status --porcelain 2>/dev/null)
if [ -z "$CHANGES" ]; then
  echo "[lazy-commit] No changes, skipping."
  exit 0
fi

git add -A

DIFF=$(git diff --cached | head -c 2000)
if [ -z "$DIFF" ]; then
  echo "[lazy-commit] Nothing staged after add, skipping."
  exit 0
fi

MSG=$(afm-cli -s "Generate a concise one-line git commit message (max 72 chars, no quotes). Summarize the diff." -p "$DIFF" 2>/dev/null || echo "auto-sync: $(date +%Y-%m-%d_%H:%M)")
MSG=$(echo "$MSG" | head -1 | cut -c1-72)

git commit -m "$MSG"

git push 2>&1 || echo "[lazy-commit] Push failed (remote not configured?)."
