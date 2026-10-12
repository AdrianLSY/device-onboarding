#!/bin/bash
set -e

# GitHub SSH for git that runs OUTSIDE fish: Claude Code, bash scripts, systemd
# units, editors. Only fish loads the `git` wrapper in
# fish/conf.d/git-multi-account.fish, and neither account's key has a default
# id_* name, so unless an agent happens to hold the right key, ssh offers GitHub
# nothing and every clone and push fails with "Permission denied (publickey)".
#
# lib/git-multi-account.sh does the work, shared with the macOS tier: a
# github.com stanza in ~/.ssh/config defaulting to the work key, and an includeIf
# in ~/.gitconfig that gives the personal account's repos the personal key,
# email and commit signing. It reads them from the fish wrapper's per-account
# helpers.
#
# pacman/github-cli.sh runs before the tweaks and sets the global identity and
# signing (the work account's) with `git config --global`. This adds only the
# includeIf to the same file, after backing it up, so neither overwrites the
# other's keys. The include comes after github-cli.sh's settings, so for the
# personal account's repos its values win.

TIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/git-multi-account.sh
. "$TIER_DIR/../lib/git-multi-account.sh"

git_multi_account fish "$TIER_DIR/fish/conf.d/git-multi-account.fish"
