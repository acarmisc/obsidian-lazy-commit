# obsidian-lazy-commit

Scheduled auto-commit and push for an Obsidian vault (or any local folder) using Apple `launchd`.

Commit messages are generated on-device by [afm-cli](https://github.com/CreevekCZ/afm-cli) (Apple Intelligence foundation model) — no API keys, no cloud, no cost.

## How it works

A `launchd` agent runs on a timer (default: every 60 minutes). Each tick:

1. Sources `~/.config/obsidian-lazy-commit/config` for `VAULT_DIR`
2. `cd`s into `VAULT_DIR` and checks for uncommitted changes via `git status --porcelain`
3. Stages everything with `git add -A`
4. Pipes the staged diff (truncated to ~2KB) to the on-device Apple Intelligence model via `afm-cli`, which returns a one-line commit message
5. Commits and pushes to the configured remote

If `afm-cli` fails (e.g. Apple Intelligence not available, wrong chip, wrong macOS), the message falls back to `auto-sync: YYYY-MM-DD_HH:MM`.

## Requirements

| Dependency | Minimum | Notes |
|---|---|---|
| macOS | 26.0 (Tahoe) or later | Required for Apple Intelligence. |
| Hardware | Apple Silicon (M1+) | Intel Macs are unsupported by Apple Intelligence. |
| [Apple Intelligence](https://support.apple.com/en-us/121112) | enabled in System Settings | Settings → Apple Intelligence → toggle on. Model downloads in the background. |
| [Homebrew](https://brew.sh) | any recent | Used to install `afm-cli` and as a prerequisite gate. |
| `git` | any recent | Pre-installed on macOS command line tools, but `install.sh` checks for it. |
| `afm-cli` | latest from `CreevekCZ/tap` | Installed automatically by `install.sh` if missing. |
| SSH key | one registered with GitHub | Only required if pushing over `git@github.com:...`. |

Verify your environment before installing:

```bash
sw_vers                          # macOS >= 26.0
uname -m                         # arm64
sysctl -n machdep.cpu.brand_string   # Apple Silicon
brew --version
git --version
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

`install.sh` is interactive only for the vault path. It will:

1. Check for `brew`, `git`, and `afm-cli` (install `afm-cli` via Homebrew if missing — installs `CreevekCZ/tap` first)
2. Prompt for the path to the Obsidian vault (or any folder) to watch
3. Create the directory if it does not exist
4. Write `~/.config/obsidian-lazy-commit/config` with `VAULT_DIR=...`
5. `git init` the vault if it is not already a git repo, and add `git@github.com:acarmisc/-obsidian-lazy-commit.git` as `origin` (override by editing `REPO_URL` at the top of `install.sh` before running)
6. Copy `com.user.obsidian-lazy-commit.plist` to `~/Library/LaunchAgents/`, patching the `__REPO_DIR__` and `__COMMIT_SCRIPT__` sentinels with real absolute paths
7. `plutil -lint` the generated plist, then `launchctl bootstrap` and `kickstart` the job

## Configuration

Everything is in one file:

```
~/.config/obsidian-lazy-commit/config
```

Current contents (with example values):

```bash
# Path to the Obsidian vault (or any folder) to watch and auto-commit.
# Can be the same as the git repo, or a separate folder that is a git working tree.
VAULT_DIR=/Users/you/Documents/ObsidianVault
```

The `commit.sh` script also reads `REPO_DIR` from the plist's `EnvironmentVariables` (used as a fallback default for `VAULT_DIR`). In normal use you only need `VAULT_DIR`.

To change the watched folder later, re-run `./install.sh` — it will detect the existing config and update `VAULT_DIR` in place.

## Logs

| Stream | Path |
|---|---|
| stdout | `/tmp/obsidian-lazy-commit.log` |
| stderr | `/tmp/obsidian-lazy-commit.err` |

Tail them while testing:

```bash
tail -f /tmp/obsidian-lazy-commit.log /tmp/obsidian-lazy-commit.err
```

## Manual run

Useful for testing or forcing an immediate commit:

```bash
./commit.sh
```

Or invoke the launchd job directly:

```bash
launchctl kickstart -k gui/$(id -u)/com.user.obsidian-lazy-commit
```

## Adjusting the schedule

The default is 3600 seconds (60 minutes). Edit the plist after install:

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
| `ERROR: '...' is not a git working tree` in logs | `VAULT_DIR` points at a non-git folder | Run `./install.sh` (it will `git init`) or `cd $VAULT_DIR && git init` manually. |
| `WARNING: Push failed` in logs | No remote, or SSH key not registered with GitHub | `cd $VAULT_DIR && git remote -v` — add with `git remote add origin <url>` and verify `ssh -T git@github.com`. |
| `plutil -lint` fails in install output | Old `~/Library/LaunchAgents/...plist` with broken edits | Delete it: `rm ~/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist` and re-run `./install.sh`. |
| Job runs but logs are silent | launchd can't find `commit.sh` (path moved) | Re-run `./install.sh` to refresh the `__COMMIT_SCRIPT__` sentinel in the plist. |
| Want to disable temporarily | — | `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.obsidian-lazy-commit.plist` |

## Uninstall

```bash
./uninstall.sh
```

This `launchctl bootout`s the job and removes the plist. The config file at `~/.config/obsidian-lazy-commit/config` is left in place (delete it manually if you want a clean uninstall). Logs in `/tmp` are also left in place.
