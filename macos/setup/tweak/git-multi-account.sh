#!/bin/bash
set -e

# GitHub SSH for git that runs OUTSIDE an interactive zsh: Claude Code, scripts,
# launchd jobs, editors. Those never load the `git` wrapper in
# zsh/rc.d/git-multi-account.zsh, and ssh-keypick deliberately leaves github.com
# alone (~/.ssh/keypick.exclude), so without this nothing offers a key and every
# clone and push fails with "Permission denied (publickey)".
#
# lib/git-multi-account.sh does the work, shared with the Linux tier: a
# github.com stanza in ~/.ssh/config defaulting to the work key, outside the
# keypick managed block so `ssh-keypick install` keeps it, and includeIfs in
# ~/.gitconfig that give the personal account's repos, cloned over SSH or HTTPS,
# the personal key, email and commit signing. It reads them from the zsh
# wrapper's per-account helpers.

TIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/git-multi-account.sh
. "$TIER_DIR/../lib/git-multi-account.sh"

git_multi_account zsh "$TIER_DIR/zsh/rc.d/git-multi-account.zsh"
