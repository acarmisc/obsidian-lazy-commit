#!/bin/bash
set -uo pipefail

# HOMEBREW_PREFIX_SENTINEL is substituted by the Homebrew formula at install
# time. The string "@@HOMEBREW_PREFIX@@" is a sentinel that is never a valid
# filesystem path, so we can distinguish a git-clone install (sentinel intact)
# from a brew install (sentinel replaced with a real prefix like
# /opt/homebrew). The commented example below shows what the file looks like
# after substitution; do not edit it back to a real path.
HOMEBREW_PREFIX_SENTINEL="@@HOMEBREW_PREFIX@@"
if [ "$HOMEBREW_PREFIX_SENTINEL" = "@@HOMEBREW_PREFIX@@" ]; then
  HOMEBREW_PREFIX=""
else
  HOMEBREW_PREFIX="$HOMEBREW_PREFIX_SENTINEL"
fi

# --self-heal: if a vault is unreadable (TCC/Background session), attempt to
# re-bootstrap the launchd job into the Aqua session automatically.
SELF_HEAL=0
case "${1:-}" in
  --self-heal) SELF_HEAL=1 ;;
esac

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
  if [ -n "$HOMEBREW_PREFIX" ]; then
    die "Config not found at $CONFIG_FILE. Run 'obsidian-lazy-commit-setup' (Homebrew) to create one."
  else
    die "Config not found at $CONFIG_FILE. Run ./install.sh first."
  fi
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

mode = data.get("mode", "interval")
if mode not in ("interval", "watch"):
    print("ERROR: top-level 'mode' must be 'interval' or 'watch'.", file=sys.stderr)
    sys.exit(11)

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
    pull = v.get("pull_before_push", False)
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
    if not isinstance(pull, bool):
        print(f"ERROR: vaults[{i}].pull_before_push must be true or false.", file=sys.stderr)
        sys.exit(12)
    if name in seen:
        print(f"ERROR: duplicate vault name '{name}'. Names must be unique.", file=sys.stderr)
        sys.exit(10)
    seen.add(name)
    cleaned.append({"name": name, "path": os.path.expanduser(pth), "remote": remote, "branch": branch, "pull": 1 if pull else 0})

print(f"MODE={mode}")
print(f"VAULT_COUNT={len(cleaned)}")
for i, v in enumerate(cleaned):
    print(f"VAULT_{i}_NAME={v['name']}")
    print(f"VAULT_{i}_PATH={v['path']}")
    print(f"VAULT_{i}_REMOTE={v['remote']}")
    print(f"VAULT_{i}_BRANCH={v['branch']}")
    print(f"VAULT_{i}_PULL={v['pull']}")
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

# Debounce for watch mode: launchd fires WatchPaths on every save (Obsidian
# does temp-file + rename per note), so let a burst settle before deciding.
# In-progress saves after this window still batch into the next commit.
if [ "${MODE:-interval}" = "watch" ]; then
  log "" "Watch mode: debouncing 5s to let save bursts settle..."
  sleep 5
fi

overall_rc=0

for ((i = 0; i < VAULT_COUNT; i++)); do
  name="VAULT_${i}_NAME";   name="${!name}"
  path="VAULT_${i}_PATH";   path="${!path}"
  remote="VAULT_${i}_REMOTE"; remote="${!remote}"
  branch="VAULT_${i}_BRANCH"; branch="${!branch}"
  pull="VAULT_${i}_PULL";   pull="${!pull}"

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

  # TCC check: in a non-Aqua (Background) launchd session macOS blocks external
  # tools from reading files under $HOME. The symptom looks like a broken repo
  # ("git init failed") but is really a session-type problem. Detect it up
  # front and point to the actual fix.
  if ! /bin/ls "$path" >/dev/null 2>&1; then
    session_name="$(launchctl managername 2>/dev/null || echo unknown)"
    log "$name" "ERROR: cannot read '$path' — TCC/Background session detected (session='$session_name')."
    log "$name" "This is NOT a git failure. Re-bootstrap the job from Terminal.app (Aqua):"
    log "$name" "  brew services restart obsidian-lazy-commit"
    log "$name" "  launchctl kickstart -k gui/$(id -u)/com.user.obsidian-lazy-commit"
    overall_rc=1
    if [ "$SELF_HEAL" -eq 1 ]; then
      PLIST_DST="$HOME/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist"
      if [ -f "$PLIST_DST" ]; then
        log "$name" "Self-healing: re-bootstrapping job into Aqua session..."
        launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
        if launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null; then
          log "$name" "Self-healed: job re-bootstrapped into Aqua. Next tick should work."
        else
          log "$name" "WARNING: self-heal bootstrap failed. Do it manually from Terminal.app."
        fi
      else
        log "$name" "Self-heal skipped: no plist at $PLIST_DST."
      fi
    fi
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

  # 3a. Guard: an in-progress rebase (from a prior pull --rebase conflict)
  # must not receive new commits. Skip until the user resolves it.
  if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    log "$name" "WARNING: rebase in progress — skipping this vault. Resolve with 'git rebase --continue' or 'git rebase --abort' in '$path'."
    overall_rc=1
    continue
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

  # 5. Scan staged files for agent provenance frontmatter and build a git
  #     trailer when present. Stays empty (commit unchanged) when no staged
  #     file carries agent/model/session_id frontmatter.
  TRAILER=""
  if [ -n "$CHANGES" ]; then
    TRAILER=$(python3 -c '
import re, subprocess, sys, collections

files = subprocess.run(["git", "diff", "--cached", "--name-only", "-z"],
                       capture_output=True, text=True).stdout.split("\0")
found = []
for f in files:
    if not f:
        continue
    try:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            head = fh.read(4096)
    except OSError:
        continue
    m = re.match(r"\A---\s*\n(.*?)\n---", head, re.S | re.M)
    if not m:
        continue
    fm = m.group(1)

    def get(key):
        mm = re.search(r"^" + key + r"\s*:\s*(.+)$", fm, re.M)
        return mm.group(1).strip().strip(chr(34) + chr(39)) if mm else ""

    agent = get("agent")
    if not agent:
        continue
    found.append((f, agent, get("model"), get("session_id")))

if not found:
    sys.exit(0)

def label(a, m, s):
    return "/".join(p for p in (a, m, s) if p)

if len(found) < 5:
    for f, a, m, s in found:
        print("Agent-written: {} ({})".format(f, label(a, m, s)))
else:
    groups = collections.Counter(label(a, m, "") for _, a, m, _ in found)
    sessions = []
    for _, a, m, s in found:
        if s and s not in sessions:
            sessions.append(s)
    agents = ", ".join(
        "{} ({} file{})".format(k, v, "s" if v > 1 else "")
        for k, v in groups.most_common()
    )
    print("Agent-written-files: {}".format(len(found)))
    print("Agents: {}".format(agents))
    if sessions:
        print("Sessions: {}".format(", ".join(sessions)))
' 2>/dev/null)
  fi

  # 6. Generate commit message via afm-cli; fall back to timestamp on failure.
  if command -v afm-cli >/dev/null 2>&1; then
    MSG=$(afm-cli -s "Generate a concise two-line git commit message (max 250 chars, no quotes). Summarize the diff giving a brief summary of the changes." -p "$DIFF" 2>/dev/null || true)
  else
    MSG=""
  fi
  if [ -z "$MSG" ]; then
    MSG="auto-sync: $(date +%Y-%m-%d_%H:%M)"
  fi
  MSG=$(echo "$MSG" | head -1 | cut -c1-72)

  # 7. Commit. With provenance, use a message file (subject + blank line +
  #     trailer) so git stores the trailer parseable by `git trailer`.
  COMMIT_OK=0
  if [ -n "$TRAILER" ]; then
    COMMIT_MSG_FILE="$(mktemp)"
    printf '%s\n\n%s\n' "$MSG" "$TRAILER" > "$COMMIT_MSG_FILE"
    git commit -F "$COMMIT_MSG_FILE" && COMMIT_OK=1
    rm -f "$COMMIT_MSG_FILE"
  else
    git commit -m "$MSG" && COMMIT_OK=1
  fi
  if [ "$COMMIT_OK" -eq 1 ]; then
    log "$name" "Committed: $MSG"
  else
    log "$name" "ERROR: Commit failed. Skipping push."
    overall_rc=1
    continue
  fi

  # 8. Optional pull --rebase before push (multi-machine vaults). Always skips
  #     push on rebase conflict; the next tick's rebase-in-progress guard takes
  #     over until the user resolves it manually.
  if [ -n "$remote" ] && [ "${pull:-0}" -eq 1 ]; then
    log "$name" "pull_before_push: running 'git pull --rebase origin $branch'..."
    if ! git pull --rebase origin "$branch" >/dev/null 2>&1; then
      log "$name" "WARNING: pull --rebase failed (conflict). Push skipped. Resolve manually in '$path'."
      if UNMERGED=$(git diff --name-only --diff-filter=U 2>/dev/null); then
        [ -n "$UNMERGED" ] && log "$name" "WARNING: conflicting files: $(echo "$UNMERGED" | tr '\n' ' ')"
      fi
      log "$name" "WARNING: next tick will skip this vault until you run 'git rebase --continue' or 'git rebase --abort'."
      overall_rc=1
      continue
    fi
  fi

  # 9. Push (only if we still have a remote we trust).
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
