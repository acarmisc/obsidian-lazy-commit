# obsidian-lazy-commit

Scheduled auto-commit and push for one or more Obsidian vaults (or any local folders) using Apple `launchd`.

Commit messages are generated on-device by [afm-cli](https://github.com/CreevekCZ/afm-cli) (Apple Intelligence foundation model) — no API keys, no cloud, no cost.

## How it works

A `launchd` agent runs on a timer (default: every 60 minutes). Each tick:

1. Parses `~/.config/obsidian-lazy-commit/config.toml` (a list of `[[vaults]]` entries)
2. For every vault, in order:
   1. `cd`s into the vault's `path`
   2. Runs `git rev-parse` to check whether it's a git working tree
      - **Not a repo** → `git init -b <branch>` (defaults to `main`), then `git remote add origin <remote>` if one is configured
      - **Already a repo** → reads `git remote get-url origin` and compares it to the configured `remote`:
        - **Matches** → push as normal
        - **Different** → log three `WARNING` lines, **skip the push** (the local commit still happens)
        - **Empty / no origin** → add the configured `origin` and continue
   3. Checks for uncommitted changes via `git status --porcelain`
   4. Stages everything with `git add -A`
   5. Pipes the staged diff (truncated to ~2KB) to the on-device Apple Intelligence model via `afm-cli`, which returns a one-line commit message
   6. Commits and (if a trusted remote exists) pushes

If `afm-cli` fails (e.g. Apple Intelligence not available, wrong chip, wrong macOS), the message falls back to `auto-sync: YYYY-MM-DD_HH:MM`.

## Requirements

| Dependency | Minimum | Notes |
|---|---|---|
| macOS | 26.0 (Tahoe) or later | Required for Apple Intelligence. |
| Hardware | Apple Silicon (M1+) | Intel Macs are unsupported by Apple Intelligence. |
| [Apple Intelligence](https://support.apple.com/en-us/121112) | enabled in System Settings | Settings → Apple Intelligence → toggle on. Model downloads in the background. |
| [Homebrew](https://brew.sh) | any recent | Used to install `afm-cli` and as a prerequisite gate. |
| `git` | any recent | Pre-installed on macOS command line tools, but `install.sh` checks for it. |
| `python3` | 3.11 or later | Used to parse the TOML config (`tomllib` is stdlib in 3.11+). Pre-installed on macOS 26. |
| `afm-cli` | latest from `CreevekCZ/tap` | Installed automatically by `install.sh` if missing. |
| SSH key | one registered with GitHub | Only required if pushing over `git@github.com:...`. |

Verify your environment before installing:

```bash
sw_vers                          # macOS >= 26.0
uname -m                         # arm64
sysctl -n machdep.cpu.brand_string   # Apple Silicon
brew --version
git --version
python3 --version                # 3.11+
```

If `afm-cli` is already installed and you want to confirm Apple Intelligence is reachable:

```bash
echo "hello world" | afm-cli -s "Reply with one word." -p -
# expect: greeting (or similar), not an error
```

## Setup

```bash
git clone git@github.com:acarmisc/-obsidian-lazy-commit.git
cd obsidian-lazy-commit
./install.sh
```

`install.sh` is interactive. It will:

1. Check for `brew`, `git`, `python3`, and `afm-cli` (installs `afm-cli` via Homebrew if missing — installs `CreevekCZ/tap` first)
2. If a **legacy** `~/.config/obsidian-lazy-commit/config` (the old `VAULT_DIR=...` file) is detected, offer to migrate it into the new TOML format
3. If a `config.toml` already exists, offer to keep the existing vault list (and only change the schedule), or start fresh
4. Otherwise, ask for each vault's `name` (unique identifier used in log lines), `path`, `remote` URL, and `branch` — enter an empty name to finish
5. Ask for the schedule in seconds (default `3600`, minimum `60`)
6. Write `~/.config/obsidian-lazy-commit/config.toml` and create the file's parent directory if missing
7. For every vault: `git init` if no `.git` exists, and add the configured `origin` (or warn if the existing origin doesn't match)
8. Copy `com.user.obsidian-lazy-commit.plist` to `~/Library/LaunchAgents/`, patching the `__COMMIT_SCRIPT__` and `__SCHEDULE__` sentinels with real values
9. `plutil -lint` the generated plist, then `launchctl bootstrap` and `kickstart` the job

## Configuration

Everything lives in one TOML file:

```
~/.config/obsidian-lazy-commit/config.toml
```

```toml
# Schedule in seconds; defaults to 3600 if omitted. Minimum 60.
schedule_seconds = 3600

# One [[vaults]] entry per folder to watch and auto-commit.
# `name` must be unique (used in log lines).
# `path` and `remote` may be absolute or use ~ ; the installer expands ~.
# `remote` may be empty (commits will stay local).
# `branch` defaults to "main" if omitted.
[[vaults]]
name = "main"
path = "/Users/you/Documents/ObsidianVault"
remote = "git@github.com:acarmisc/-obsidian-lazy-commit.git"
branch = "main"

[[vaults]]
name = "work"
path = "~/WorkVault"
remote = "git@github.com:acarmisc/work-vault.git"
# branch omitted -> defaults to "main"

[[vaults]]
name = "scratch"
path = "/Users/you/Scratch"
remote = ""                # local-only; no push
```

### How the per-vault remote is handled

On every tick, for each vault, `commit.sh` re-checks the git state — it does not trust the installer. The matrix is:

| Repo state | Configured `remote` | Action |
|---|---|---|
| No `.git` | anything | `git init -b <branch>`, then `git remote add origin <remote>` (if non-empty) |
| Repo, no `origin` | non-empty | `git remote add origin <remote>` and push as normal |
| Repo, `origin` matches config | (any) | Push as normal |
| Repo, `origin` **differs** from config | (any) | **Skip push**, log three `WARNING` lines, leave `origin` untouched. Local commit still happens. |
| Repo | empty in config | No push. If repo has an existing `origin`, log it but don't change it. |

To resolve a mismatched `origin`, either edit the TOML to match the existing remote or run `git remote set-url origin <url>` in the vault directory.

### Adding or removing vaults later

Re-run `./install.sh`. It will:

- detect the existing `config.toml`
- ask "Keep the existing vault list? [Y/n]"
- if you say **No**, walk you through a fresh list (the old config is overwritten)
- if you say **Yes**, only the schedule is re-asked and the plist is updated

## Logs

| Stream | Path |
|---|---|
| stdout | `/tmp/obsidian-lazy-commit.log` |
| stderr | `/tmp/obsidian-lazy-commit.err` |

Every line is prefixed with a timestamp and, for vault-scoped lines, the vault name in brackets, e.g.:

```
[2026-06-08 11:41:53] [alpha] Begin
[2026-06-08 11:41:53] [alpha] Path: /Users/you/Documents/ObsidianVault
[2026-06-08 11:41:53] [alpha] WARNING: existing origin 'git@github.com:old/repo.git' differs from configured 'git@github.com:new/repo.git'.
[2026-06-08 11:41:53] [alpha] WARNING: Skipping push for this vault to avoid pushing to the wrong remote.
[2026-06-08 11:41:53] [alpha] WARNING: Fix with: (cd '/Users/you/Documents/ObsidianVault' && git remote set-url origin 'git@github.com:new/repo.git')
```

Tail them while testing:

```bash
tail -f /tmp/obsidian-lazy-commit.log /tmp/obsidian-lazy-commit.err
```

## Manual run

Useful for testing or forcing an immediate run:

```bash
./commit.sh
```

Or invoke the launchd job directly:

```bash
launchctl kickstart -k gui/$(id -u)/com.user.obsidian-lazy-commit
```

## Adjusting the schedule

Two options:

1. Re-run `./install.sh` and answer the schedule prompt (or just say "Y" to keep the existing vault list and change only the schedule).
2. Edit the plist directly:

   ```bash
   plutil -replace StartInterval -integer 900 \
     ~/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist
   launchctl kickstart -k gui/$(id -u)/com.user.obsidian-lazy-commit
   ```

For event-driven triggers instead of an interval (e.g. on file system changes), see the [launchd plist reference](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html) and replace `StartInterval` with a `WatchPaths` array.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `afm-cli not found` during install | Homebrew not installed | Install [Homebrew](https://brew.sh) first, re-run `./install.sh`. |
| Commit message is always `auto-sync: YYYY-MM-DD_HH:MM` | `afm-cli` failing (Apple Intelligence off, Intel Mac, wrong macOS) | Enable Apple Intelligence in System Settings, or update to macOS 26+ on Apple Silicon. |
| `ERROR: '...' is not a git working tree` in logs | `path` for a vault points at a non-git folder | Re-run `./install.sh` (it will `git init`), or `cd <path> && git init` manually. |
| `WARNING: existing origin 'X' differs from configured 'Y'` | You changed the TOML but the existing repo's `origin` was never updated | Run `cd <vault-path> && git remote set-url origin <new-url>`, or revert the TOML. |
| `WARNING: Push failed` in logs | No remote, or SSH key not registered with GitHub | `cd <vault-path> && git remote -v` — add with `git remote add origin <url>` and verify `ssh -T git@github.com`. |
| `plutil -lint` fails in install output | Old `~/Library/LaunchAgents/...plist` with broken edits | Delete it: `rm ~/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist` and re-run `./install.sh`. |
| Job runs but logs are silent | launchd can't find `commit.sh` (path moved) | Re-run `./install.sh` to refresh the `__COMMIT_SCRIPT__` sentinel in the plist. |
| `python3 < 3.11 (no tomllib)` error | macOS older than 26 (or Homebrew Python not on PATH) | macOS 26 ships Python 3.11+; otherwise `brew install python`. |
| Want to disable temporarily | — | `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist` |

## Uninstall

```bash
./uninstall.sh
```

This `launchctl bootout`s the job and removes the plist. The config file at `~/.config/obsidian-lazy-commit/config.toml` and any `config.migrated` from the legacy migration are left in place (delete them manually if you want a clean uninstall). Logs in `/tmp` are also left in place.
