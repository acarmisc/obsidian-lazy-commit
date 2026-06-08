#!/bin/bash
# Back-compat shim. Prefer `./bin/obsidian-lazy-commit-setup` for the new
# code, or `brew install ...` for a Homebrew install. This wrapper just
# delegates to the new setup script and keeps the old `install.sh` entry
# point working for users who already have it in their muscle memory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -x "$SCRIPT_DIR/bin/obsidian-lazy-commit-setup" ]; then
  exec "$SCRIPT_DIR/bin/obsidian-lazy-commit-setup"
fi

echo "ERROR: bin/obsidian-lazy-commit-setup not found in repo." >&2
echo "Did you clone the full repo? Try: git pull" >&2
exit 1
