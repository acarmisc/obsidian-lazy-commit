#!/bin/bash
set -euo pipefail

DEFAULT_REPO_URL="git@github.com:acarmisc/-obsidian-lazy-commit.git"
REPO_DIR_DEFAULT="$HOME/.local/share/obsidian-lazy-commit"
SCHEDULE_DEFAULT=3600
SENTINEL_SCHEDULE="$SCHEDULE_DEFAULT"

if ! command -v python3 &>/dev/null; then
  echo "[install] ERROR: python3 is required to parse the TOML config." >&2
  exit 1
fi

if ! command -v git &>/dev/null; then
  echo "[install] ERROR: git is required but not found in PATH." >&2
  exit 1
fi

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMIT_SCRIPT="$SCRIPT_DIR/commit.sh"
PLIST_SRC="$SCRIPT_DIR/com.user.obsidian-lazy-commit.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist"
CONFIG_DIR="$HOME/.config/obsidian-lazy-commit"
CONFIG_FILE="$CONFIG_DIR/config.toml"
LEGACY_CONFIG_FILE="$CONFIG_DIR/config"

mkdir -p "$CONFIG_DIR"

# --- Migrate legacy key=value config if present ---------------------------------
if [ -f "$LEGACY_CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
  echo "[install] Legacy config file detected at $LEGACY_CONFIG_FILE."
  read -p "[install] Migrate it to the new TOML format? [Y/n] " MIGRATE_ANSWER
  MIGRATE_ANSWER="${MIGRATE_ANSWER:-Y}"
  if [[ "$MIGRATE_ANSWER" =~ ^[Yy]$ ]]; then
    # shellcheck disable=SC1090
    LEGACY_VAULT_DIR="$(source "$LEGACY_CONFIG_FILE" && echo "${VAULT_DIR:-}")"
    if [ -n "$LEGACY_VAULT_DIR" ]; then
      LEGACY_VAULT_DIR_ABS="$(cd "$LEGACY_VAULT_DIR" 2>/dev/null && pwd || echo "$LEGACY_VAULT_DIR")"
      cat > "$CONFIG_FILE" <<EOF
# Migrated from the legacy key=value config.
# Edit this file to add more vaults or change remotes.

[[vaults]]
name = "default"
path = "$LEGACY_VAULT_DIR_ABS"
remote = "$DEFAULT_REPO_URL"
branch = "main"
EOF
      mv "$LEGACY_CONFIG_FILE" "${LEGACY_CONFIG_FILE}.migrated"
      echo "[install] Migrated to $CONFIG_FILE (legacy file kept as .migrated)."
    else
      echo "[install] Legacy file had no VAULT_DIR; ignoring. You will configure from scratch."
    fi
  else
    echo "[install] Skipping migration. Legacy file will be ignored."
  fi
fi

# --- Collect / refresh vault list -----------------------------------------------
# We always re-prompt for the vault list, but pre-populate from the existing TOML
# so users can re-run install.sh to edit the list (matches the old single-vault
# "re-run to update" mental model).
declare -a EXISTING_NAMES=()
declare -a EXISTING_PATHS=()
declare -a EXISTING_REMOTES=()
declare -a EXISTING_BRANCHES=()

if [ -f "$CONFIG_FILE" ]; then
  if EXISTING=$(python3 - <<PY 2>/dev/null
import os, tomllib
with open("$CONFIG_FILE", "rb") as f:
    data = tomllib.load(f)
for v in (data.get("vaults") or []):
    print(f"{v.get('name','')}|{v.get('path','')}|{v.get('remote','')}|{v.get('branch','main')}")
PY
  ); then
    while IFS='|' read -r n p r b; do
      EXISTING_NAMES+=("$n")
      EXISTING_PATHS+=("$p")
      EXISTING_REMOTES+=("$r")
      EXISTING_BRANCHES+=("$b")
    done <<< "$EXISTING"
  fi
  echo "[install] Existing config found with ${#EXISTING_NAMES[@]} vault(s)."
  read -p "[install] Keep the existing vault list? [Y/n] " KEEP_ANSWER
  KEEP_ANSWER="${KEEP_ANSWER:-Y}"
else
  KEEP_ANSWER="n"
fi

declare -a VAULT_NAMES=()
declare -a VAULT_PATHS=()
declare -a VAULT_REMOTES=()
declare -a VAULT_BRANCHES=()

if [[ "$KEEP_ANSWER" =~ ^[Yy]$ ]] && [ "${#EXISTING_NAMES[@]}" -gt 0 ]; then
  VAULT_NAMES=("${EXISTING_NAMES[@]}")
  VAULT_PATHS=("${EXISTING_PATHS[@]}")
  VAULT_REMOTES=("${EXISTING_REMOTES[@]}")
  VAULT_BRANCHES=("${EXISTING_BRANCHES[@]}")
else
  echo
  echo "[install] Add vaults. Enter an empty line at the name prompt to finish."
  i=0
  while :; do
    i=$((i+1))
    default_name="vault${i}"
    read -r -p "[install] Name for vault #$i (default: $default_name, empty to finish): " NAME_INPUT
    if [ -z "$NAME_INPUT" ]; then
      break
    fi
    NAME_INPUT="${NAME_INPUT:-$default_name}"
    # Names: alnum, dash, underscore.
    if ! [[ "$NAME_INPUT" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "[install] ERROR: name must be alphanumeric, dash, or underscore. Try again." >&2
      i=$((i-1))
      continue
    fi
    dup=0
    for existing in "${VAULT_NAMES[@]:-}"; do
      if [ "$existing" = "$NAME_INPUT" ]; then
        echo "[install] ERROR: name '$NAME_INPUT' already used in this session. Try again." >&2
        dup=1
        break
      fi
    done
    if [ "$dup" -eq 1 ]; then
      i=$((i-1))
      continue
    fi

    read -r -p "[install] Path to vault '$NAME_INPUT': " PATH_INPUT
    if [ -z "$PATH_INPUT" ]; then
      echo "[install] ERROR: path is required. Try again." >&2
      i=$((i-1))
      continue
    fi
    if [ ! -d "$PATH_INPUT" ]; then
      read -r -p "[install] Path does not exist. Create '$PATH_INPUT'? [y/N] " CREATE_ANSWER
      if [[ "$CREATE_ANSWER" =~ ^[Yy]$ ]]; then
        mkdir -p "$PATH_INPUT"
        echo "[install] Created $PATH_INPUT"
      else
        echo "[install] Skipped. Re-enter this vault or pick a different path." >&2
        i=$((i-1))
        continue
      fi
    fi
    PATH_ABS="$(cd "$PATH_INPUT" && pwd)"

    read -r -p "[install] Git remote URL for '$NAME_INPUT' (default: $DEFAULT_REPO_URL, empty = none): " REMOTE_INPUT
    if [ -z "$REMOTE_INPUT" ]; then
      REMOTE_INPUT="$DEFAULT_REPO_URL"
    fi
    read -r -p "[install] Override remote to empty? [y/N] " CLEAR_REMOTE
    if [[ "$CLEAR_REMOTE" =~ ^[Yy]$ ]]; then
      REMOTE_INPUT=""
    fi

    read -r -p "[install] Default branch (default: main): " BRANCH_INPUT
    BRANCH_INPUT="${BRANCH_INPUT:-main}"

    VAULT_NAMES+=("$NAME_INPUT")
    VAULT_PATHS+=("$PATH_ABS")
    VAULT_REMOTES+=("$REMOTE_INPUT")
    VAULT_BRANCHES+=("$BRANCH_INPUT")
    echo "[install] Added vault '$NAME_INPUT' -> $PATH_ABS"
    echo
  done
fi

if [ "${#VAULT_NAMES[@]}" -eq 0 ]; then
  echo "[install] ERROR: at least one vault is required." >&2
  exit 1
fi

# Optional schedule override.
echo
read -p "[install] Schedule in seconds (default: $SCHEDULE_DEFAULT): " SCHEDULE_INPUT
SCHEDULE_INPUT="${SCHEDULE_INPUT:-$SCHEDULE_DEFAULT}"
if ! [[ "$SCHEDULE_INPUT" =~ ^[0-9]+$ ]] || [ "$SCHEDULE_INPUT" -lt 60 ]; then
  echo "[install] ERROR: schedule must be an integer >= 60." >&2
  exit 1
fi
SENTINEL_SCHEDULE="$SCHEDULE_INPUT"

# --- Write the TOML config ------------------------------------------------------
{
  echo "# Obsidian lazy commit configuration"
  echo "# One [[vaults]] entry per folder you want auto-committed and pushed."
  echo "# name must be unique and is used in log lines."
  echo "# remote may be empty (commits will stay local)."
  echo "# branch defaults to \"main\" if omitted."
  echo "schedule_seconds = $SCHEDULE_INPUT"
  echo
  for i in "${!VAULT_NAMES[@]}"; do
    n="${VAULT_NAMES[$i]}"
    p="${VAULT_PATHS[$i]}"
    r="${VAULT_REMOTES[$i]}"
    b="${VAULT_BRANCHES[$i]}"
    echo "[[vaults]]"
    echo "name = \"$n\""
    echo "path = \"$p\""
    if [ -n "$r" ]; then
      echo "remote = \"$r\""
    fi
    if [ -n "$b" ] && [ "$b" != "main" ]; then
      echo "branch = \"$b\""
    fi
    echo
  done
} > "$CONFIG_FILE"

echo "[install] Wrote config to $CONFIG_FILE with ${#VAULT_NAMES[@]} vault(s)."

# --- Init / validate git per vault (best-effort; commit.sh re-checks on every run) ---
for i in "${!VAULT_NAMES[@]}"; do
  n="${VAULT_NAMES[$i]}"
  p="${VAULT_PATHS[$i]}"
  r="${VAULT_REMOTES[$i]}"
  b="${VAULT_BRANCHES[$i]}"

  if [ ! -d "$p/.git" ]; then
    echo "[install] [$n] No git repo in $p, initializing (branch=$b)..."
    if ! (cd "$p" && git init -b "$b" 2>/dev/null) ; then
      (cd "$p" && git init >/dev/null 2>&1) || true
      (cd "$p" && git checkout -B "$b" >/dev/null 2>&1) || true
    fi
  fi
  if [ -n "$r" ]; then
    existing="$(cd "$p" && git remote get-url origin 2>/dev/null || true)"
    if [ -z "$existing" ]; then
      (cd "$p" && git remote add origin "$r" 2>/dev/null) || true
      echo "[install] [$n] Added origin -> $r"
    elif [ "$existing" != "$r" ]; then
      echo "[install] [$n] NOTE: existing origin '$existing' differs from configured '$r'."
      echo "[install] [$n]   commit.sh will warn and skip push until you reconcile."
      echo "[install] [$n]   To accept the new URL: (cd '$p' && git remote set-url origin '$r')"
    else
      echo "[install] [$n] Origin already set to $r"
    fi
  fi
done

# --- Install the single plist ---------------------------------------------------
mkdir -p "$(dirname "$PLIST_DST")"
cp "$PLIST_SRC" "$PLIST_DST"
sed -i.bak \
  -e "s|__COMMIT_SCRIPT__|$COMMIT_SCRIPT|g" \
  -e "s|__SCHEDULE__|$SENTINEL_SCHEDULE|g" \
  "$PLIST_DST"
rm -f "$PLIST_DST.bak"

if ! plutil -lint "$PLIST_DST" >/dev/null; then
  echo "[install] ERROR: generated plist failed plutil -lint. Aborting." >&2
  exit 1
fi
echo "[install] Installed plist to $PLIST_DST (commit.sh=$COMMIT_SCRIPT, every ${SENTINEL_SCHEDULE}s)"

UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"
launchctl enable "gui/$UID_NUM/com.user.obsidian-lazy-commit" 2>/dev/null || true
launchctl kickstart -k "gui/$UID_NUM/com.user.obsidian-lazy-commit" 2>/dev/null || true
echo "[install] Loaded launchd job: com.user.obsidian-lazy-commit"

echo "[install] Done. Logs: /tmp/obsidian-lazy-commit.{log,err}"
