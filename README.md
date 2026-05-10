# obsidian-lazy-commit

Scheduled auto-commit and push for an Obsidian vault (or any local folder) using Apple `launchd`.

Commit messages are generated on-device by [afm-cli](https://github.com/CreevekCZ/afm-cli) (Apple Intelligence foundation model) — no API keys, no cloud, no cost.

## How it works

A `launchd` agent runs on a timer (default: every 60 minutes). Each tick:

1. Checks for uncommitted changes via `git status --porcelain`
2. Stages everything with `git add -A`
3. Pipes the staged diff to Apple Intelligence on-device model (`afm-cli`) which returns a one-line commit message
4. Commits and pushes to the configured remote

If `afm-cli` fails (e.g. Apple Intelligence not available), it falls back to `auto-sync: YYYY-MM-DD_HH:MM`.

## Requirements

- macOS Tahoe (26.0) or later with Apple Silicon
- [Apple Intelligence](https://support.apple.com/en-us/121112) enabled in System Settings

## Setup

```bash
git clone git@github.com:acarmisc/-obsidian-lazy-commit.git
cd obsidian-lazy-commit
./install.sh
```

`install.sh` will:

1. Install `afm-cli` via Homebrew if not already present
2. Create `~/.config/obsidian-lazy-commit/config` with defaults
3. Copy the plist to `~/Library/LaunchAgents/`
4. Load the job with `launchctl bootstrap`

## Watch a different folder

By default `commit.sh` watches its own repo. To watch an Obsidian vault or any other directory, edit:

```
~/.config/obsidian-lazy-commit/config
```

and set:

```bash
VAULT_DIR=/path/to/your/obsidian/vault
REPO_DIR=/Users/andrea/Projects/personal/obsidian-lazy-commit
```

The script `cd`s into `REPO_DIR` (where git lives) but stages all changes under `VAULT_DIR`.

## Logs

| Stream | Path |
|---|---|
| stdout | `/tmp/obsidian-lazy-commit.log` |
| stderr | `/tmp/obsidian-lazy-commit.err` |

## Manual run

```bash
./commit.sh
```

## Uninstall

```bash
./uninstall.sh
```
