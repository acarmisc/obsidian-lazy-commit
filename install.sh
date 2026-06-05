#!/bin/bash
set -euo pipefail

REPO_URL="git@github.com:acarmisc/-obsidian-lazy-commit.git"
REPO_DIR_DEFAULT="$HOME/.local/share/obsidian-lazy-commit"

if ! command -v afm-cli &>/dev/null; then
  echo "[install] afm-cli not found, installing via Homebrew..."
  if ! command -v brew &>/dev/null; then
    echo "[install] ERROR: Homebrew is required to install afm-cli." >&2
    echo "[install] Install Homebrew first: https://brew.sh" >&2
    exit 1
  fi
  brew tap CreevekCZ/tap
  brew install afm-cli
fi

if ! command -v git &>/dev/null; then
  echo "[install] ERROR: git is required but not found in PATH." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMIT_SCRIPT="$SCRIPT_DIR/commit.sh"
PLIST_SRC="$SCRIPT_DIR/com.user.obsidian-lazy-commit.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist"
CONFIG_DIR="$HOME/.config/obsidian-lazy-commit"
CONFIG_FILE="$CONFIG_DIR/config"

mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  read -p "Enter the path to your Obsidian vault (default: $REPO_DIR_DEFAULT): " VAULT_DIR_INPUT
  VAULT_DIR_INPUT="${VAULT_DIR_INPUT:-$REPO_DIR_DEFAULT}"
  if [ ! -d "$VAULT_DIR_INPUT" ]; then
    echo "[install] Creating vault directory at $VAULT_DIR_INPUT"
    mkdir -p "$VAULT_DIR_INPUT"
  fi
  REPO_DIR_ABS="$(cd "$VAULT_DIR_INPUT" && pwd)"

  cat > "$CONFIG_FILE" <<EOF
# Path to the Obsidian vault (or any folder) to watch and auto-commit.
# Can be the same as the git repo, or a separate folder that is a git working tree.
VAULT_DIR=$REPO_DIR_ABS
EOF
  echo "[install] Created config at $CONFIG_FILE with VAULT_DIR=$REPO_DIR_ABS"
else
  # shellcheck disable=SC1090
  CURRENT_VAULT="$(source "$CONFIG_FILE" && echo "${VAULT_DIR:-}")"
  read -p "Enter the path to your Obsidian vault (current: ${CURRENT_VAULT:-(unset)}): " VAULT_DIR_INPUT
  VAULT_DIR_INPUT="${VAULT_DIR_INPUT:-$CURRENT_VAULT}"
  if [ -z "$VAULT_DIR_INPUT" ]; then
    echo "[install] ERROR: VAULT_DIR is required." >&2
    exit 1
  fi
  if [ ! -d "$VAULT_DIR_INPUT" ]; then
    echo "[install] ERROR: '$VAULT_DIR_INPUT' does not exist." >&2
    exit 1
  fi
  REPO_DIR_ABS="$(cd "$VAULT_DIR_INPUT" && pwd)"
  sed -i.bak "s|^VAULT_DIR=.*|VAULT_DIR=$REPO_DIR_ABS|" "$CONFIG_FILE"
  rm -f "$CONFIG_FILE.bak"
  echo "[install] Updated config at $CONFIG_FILE with VAULT_DIR=$REPO_DIR_ABS"
fi

# Init a git repo in the vault if one does not exist, and configure the remote.
if [ ! -d "$REPO_DIR_ABS/.git" ]; then
  echo "[install] No git repo found in $REPO_DIR_ABS, initializing..."
  (cd "$REPO_DIR_ABS" && git init -b main)
  if [ -n "${REPO_URL:-}" ]; then
    (cd "$REPO_DIR_ABS" && git remote add origin "$REPO_URL" 2>/dev/null) || true
  fi
fi

cp "$PLIST_SRC" "$PLIST_DST"
sed -i.bak "s|__REPO_DIR__|$REPO_DIR_ABS|g; s|__COMMIT_SCRIPT__|$COMMIT_SCRIPT|g" "$PLIST_DST"
rm -f "$PLIST_DST.bak"
echo "[install] Installed plist to $PLIST_DST (REPO_DIR=$REPO_DIR_ABS, commit.sh=$COMMIT_SCRIPT)"

# Validate the plist before loading it.
if ! plutil -lint "$PLIST_DST" >/dev/null; then
  echo "[install] ERROR: generated plist failed plutil -lint. Aborting." >&2
  exit 1
fi

UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"
launchctl enable "gui/$UID_NUM/com.user.obsidian-lazy-commit" 2>/dev/null || true
launchctl kickstart -k "gui/$UID_NUM/com.user.obsidian-lazy-commit" 2>/dev/null || true
echo "[install] Loaded launchd job: com.user.obsidian-lazy-commit"

echo "[install] Done. Job runs every 60 minutes. Logs: /tmp/obsidian-lazy-commit.{log,err}"
