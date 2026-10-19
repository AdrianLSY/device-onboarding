#!/bin/bash
set -e

# Wire the gitleaks secret-scanning tripwire (.pre-commit-config.yaml) into this repo's
# git hooks. The package module (brew, or pacman on Linux) runs first, so `pre-commit`
# is already installed by now. The Linux tier runs this file through
# linux/setup/tweak/pre-commit.sh, so keep it portable.
# Idempotent: `pre-commit install` just (re)writes .git/hooks/pre-commit.
# The repo lives at an external path (canonically ~/.dotfiles), NOT ~/.config, so
# resolve it from this script's own location (macos/setup/tweak/ -> repo root).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Not a git checkout (e.g. a downloaded archive): no commits to guard. `-e`, not
# `-d`, so a worktree's `.git` file counts too.
if [ ! -e "$REPO/.git" ]; then
    echo "pre-commit: $REPO is not a git checkout; skipping hook install."
    exit 0
fi

# This hook is the repo's primary secret defense, so a missing tool fails loudly
# rather than skipping silently (a silent skip hid the old ~/.config path bug).
if ! command -v pre-commit >/dev/null 2>&1; then
    echo "🔴 pre-commit not found on PATH; gitleaks hook NOT installed." >&2
    exit 1
fi

(cd "$REPO" && pre-commit install)
