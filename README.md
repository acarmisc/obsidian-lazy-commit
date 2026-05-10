# obsidian-lazy-commit

Scheduled auto-commit and push for an Obsidian vault (or any local folder) using `launchd`.

Uses [afm-cli](https://github.com/CreevekCZ/afm-cli) with Apple Intelligence to generate commit messages from the diff.

## How it works

A `launchd` agent runs `commit.sh` every 60 minutes. It:

1. Checks for uncommitted changes
2. Stages everything with `git add -A`
3. Pipes the diff to `afm-cli` (Apple Intelligence on-device model) to generate a commit message
4. Commits and pushes to the configured remote

## Setup

```bash
# 1. Install afm-cli
brew install CreevekCZ/tap/afm-cli

# 2. Configure git remote in this repo
cd /Users/andrea/Projects/personal/obsidian-lazy-commit
git remote add origin <your-repo-url>

# 3. Install the launchd job
./install.sh
```

## Custom source folder

By default the script commits this repo itself. To watch a different folder (e.g. an Obsidian vault), edit:

```
~/.config/obsidian-lazy-commit/config
```

and set `VAULT_DIR=/path/to/your/vault`.

## Manual run

```bash
./commit.sh
```

## Logs

- Stdout: `/tmp/obsidian-lazy-commit.log`
- Stderr: `/tmp/obsidian-lazy-commit.err`

## Uninstall

```bash
./uninstall.sh
```
