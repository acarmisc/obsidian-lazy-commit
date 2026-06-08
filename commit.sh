#!/bin/bash
set -uo pipefail

# Resolve our own location, regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG_DIR="${OBSIDIAN_LAZY_COMMIT_CONFIG_DIR:-$HOME/.config/obsidian-lazy-commit}"
CONFIG_FILE="$CONFIG_DIR/config.toml"

log() {
  local vault="${1:-}"
  local msg="${2:-}"
  local prefix
  if [ -n "$vault" ]; then
    prefix="[$vault]"
  else
    prefix=""
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $prefix $msg"
}

die() {
  log "" "ERROR: $1" >&2
  exit 1
}

if [ ! -f "$CONFIG_FILE" ]; then
  die "Config not found at $CONFIG_FILE. Run install.sh first."
fi

# Parse TOML config with Python (tomllib is stdlib in 3.11+).
# Emits a shell-eval-able string: VAULT_COUNT, then VAULT_N_NAME / _PATH / _REMOTE / _BRANCH.
read_toml() {
  CONFIG_FILE_PATH="$1" python3 - <<'PY'
import os, sys, json

try:
    import tomllib
except ModuleNotFoundError:
    print("ERROR: python3 < 3.11 (no tomllib). Cannot parse TOML config.", file=sys.stderr)
    sys.exit(2)

path = os.environ["CONFIG_FILE_PATH"]
with open(path, "rb") as f:
    try:
        data = tomllib.load(f)
    except Exception as e:
        print(f"ERROR: failed to parse {path}: {e}", file=sys.stderr)
        sys.exit(3)

vaults = data.get("vaults") or []
if not isinstance(vaults, list) or not vaults:
    print("ERROR: config must define a non-empty [[vaults]] array.", file=sys.stderr)
    sys.exit(4)

seen = set()
cleaned = []
for i, v in enumerate(vaults):
    if not isinstance(v, dict):
        print(f"ERROR: vaults[{i}] is not a table.", file=sys.stderr)
        sys.exit(5)
    name = v.get("name")
    pth = v.get("path")
    remote = v.get("remote", "")
    branch = v.get("branch", "main")
    if not isinstance(name, str) or not name.strip():
        print(f"ERROR: vaults[{i}].name is required and must be a non-empty string.", file=sys.stderr)
        sys.exit(6)
    if not isinstance(pth, str) or not pth.strip():
        print(f"ERROR: vaults[{i}].path is required and must be a non-empty string.", file=sys.stderr)
        sys.exit(7)
    if not isinstance(remote, str):
        print(f"ERROR: vaults[{i}].remote must be a string if present.", file=sys.stderr)
        sys.exit(8)
    if not isinstance(branch, str) or not branch.strip():
        print(f"ERROR: vaults[{i}].branch must be a non-empty string.", file=sys.stderr)
        sys.exit(9)
    if name in seen:
        print(f"ERROR: duplicate vault name '{name}'. Names must be unique.", file=sys.stderr)
        sys.exit(10)
    seen.add(name)
    cleaned.append({"name": name, "path": os.path.expanduser(pth), "remote": remote, "branch": branch})

print(f"VAULT_COUNT={len(cleaned)}")
for i, v in enumerate(cleaned):
    print(f"VAULT_{i}_NAME={v['name']}")
    print(f"VAULT_{i}_PATH={v['path']}")
    print(f"VAULT_{i}_REMOTE={v['remote']}")
    print(f"VAULT_{i}_BRANCH={v['branch']}")
PY
}

if ! PARSED=$(read_toml "$CONFIG_FILE"); then
  # read_toml already printed the actual error to stderr.
  exit 1
fi
eval "$PARSED"

if [ "${VAULT_COUNT:-0}" -eq 0 ]; then
  die "No vaults configured in $CONFIG_FILE."
fi

# Ensure git is available before we try to do anything per-vault.
if ! command -v git >/dev/null 2>&1; then
  die "git is required but not found in PATH."
fi

log "" "Started; processing $VAULT_COUNT vault(s)."

overall_rc=0

for ((i = 0; i < VAULT_COUNT; i++)); do
  name="VAULT_${i}_NAME";   name="${!name}"
  path="VAULT_${i}_PATH";   path="${!path}"
  remote="VAULT_${i}_REMOTE"; remote="${!remote}"
  branch="VAULT_${i}_BRANCH"; branch="${!branch}"

  log "$name" "Begin"
  log "$name" "Path: $path"
  if [ -n "$remote" ]; then
    log "$name" "Remote: $remote"
  else
    log "$name" "Remote: (none configured)"
  fi
  log "$name" "Branch: $branch"

  if [ ! -d "$path" ]; then
    log "$name" "ERROR: vault path '$path' does not exist. Skipping."
    overall_rc=1
    continue
  fi

  if ! cd "$path"; then
    log "$name" "ERROR: could not cd into '$path'. Skipping."
    overall_rc=1
    continue
  fi

  # 1. Make sure it's a git working tree. If not, git init + (optionally) set remote.
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "$name" "No git repo found. Running: git init -b $branch"
    if ! git init -b "$branch" >/dev/null 2>&1; then
      # Older git may not support -b; fall back.
      log "$name" "git init -b failed, retrying without -b"
      if ! git init >/dev/null 2>&1; then
        log "$name" "ERROR: git init failed in '$path'. Skipping."
        overall_rc=1
        continue
      fi
      # Make sure the requested branch exists / is checked out.
      if ! git symbolic-ref --short HEAD >/dev/null 2>&1; then
        git checkout -b "$branch" >/dev/null 2>&1 || true
      elif [ "$(git symbolic-ref --short HEAD 2>/dev/null)" != "$branch" ]; then
        git checkout -B "$branch" >/dev/null 2>&1 || true
      fi
    fi
    if [ -n "$remote" ]; then
      if git remote add origin "$remote" 2>/dev/null; then
        log "$name" "Added origin -> $remote"
      else
        log "$name" "WARNING: could not add origin remote."
      fi
    fi
  else
    # 2. Repo exists: validate the existing origin against the configured remote.
    existing_remote="$(git remote get-url origin 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      if [ -z "$existing_remote" ]; then
        if git remote add origin "$remote" 2>/dev/null; then
          log "$name" "Added missing origin -> $remote"
        else
          log "$name" "WARNING: could not add origin remote."
        fi
      elif [ "$existing_remote" != "$remote" ]; then
        log "$name" "WARNING: existing origin '$existing_remote' differs from configured '$remote'."
        log "$name" "WARNING: Skipping push for this vault to avoid pushing to the wrong remote."
        log "$name" "WARNING: Fix with: (cd '$path' && git remote set-url origin '$remote')"
        remote=""  # disable push below
      else
        log "$name" "Origin matches configured remote."
      fi
    else
      if [ -n "$existing_remote" ]; then
        log "$name" "No remote configured in TOML, but repo has origin=$existing_remote. Will push to existing origin."
      else
        log "$name" "No remote configured and repo has no origin. Commits will stay local."
      fi
    fi

    # Make sure we're on the requested branch if one was set.
    current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ -n "$current_branch" ] && [ "$current_branch" != "$branch" ]; then
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        if ! git checkout "$branch" >/dev/null 2>&1; then
          log "$name" "WARNING: could not switch to branch '$branch'. Continuing on '$current_branch'."
        fi
      else
        if git checkout -b "$branch" >/dev/null 2>&1; then
          log "$name" "Created and checked out branch '$branch'."
        else
          log "$name" "WARNING: could not create branch '$branch'. Continuing on '$current_branch'."
        fi
      fi
    fi
  fi

  # 3. Detect changes.
  if ! CHANGES=$(git status --porcelain 2>/dev/null); then
    log "$name" "ERROR: 'git status' failed. Skipping."
    overall_rc=1
    continue
  fi
  if [ -z "$CHANGES" ]; then
    log "$name" "No changes, skipping."
    continue
  fi

  # 4. Stage and build diff for the LLM.
  git add -A
  DIFF=$(git diff --cached)
  DIFF="${DIFF:0:2000}"
  if [ -z "$DIFF" ]; then
    log "$name" "Nothing staged after add, skipping."
    continue
  fi

  # 5. Generate commit message via afm-cli; fall back to timestamp on failure.
  if command -v afm-cli >/dev/null 2>&1; then
    MSG=$(afm-cli -s "Generate a concise two-line git commit message (max 250 chars, no quotes). Summarize the diff giving a brief summary of the changes." -p "$DIFF" 2>/dev/null || true)
  else
    MSG=""
  fi
  if [ -z "$MSG" ]; then
    MSG="auto-sync: $(date +%Y-%m-%d_%H:%M)"
  fi
  MSG=$(echo "$MSG" | head -1 | cut -c1-72)

  # 6. Commit.
  if git commit -m "$MSG"; then
    log "$name" "Committed: $MSG"
  else
    log "$name" "ERROR: Commit failed. Skipping push."
    overall_rc=1
    continue
  fi

  # 7. Push (only if we still have a remote we trust).
  if [ -n "$remote" ]; then
    PUSH_OUTPUT=$(git push 2>&1) || PUSH_RC=$?
    echo "$PUSH_OUTPUT" >> /tmp/obsidian-lazy-commit.log
    if [ "${PUSH_RC:-0}" -eq 0 ]; then
      log "$name" "Pushed successfully"
    else
      log "$name" "WARNING: Push failed (rc=${PUSH_RC}). Check remote/auth in the log above."
      overall_rc=1
    fi
  else
    log "$name" "Push skipped (no remote configured or origin mismatch)."
  fi

  log "$name" "Done"
done

log "" "Completed (rc=$overall_rc)"
exit "$overall_rc"
