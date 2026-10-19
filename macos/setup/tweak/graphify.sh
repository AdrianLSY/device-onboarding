#!/bin/bash
set -e

# The Linux tier runs this file through linux/setup/tweak/graphify.sh, so keep
# it portable.

# NOTE: the double-y is intentional — the PyPI package is `graphifyy`
# (plain `graphify` does not exist on PyPI). Verified 2026-07-02.
uv tool install graphifyy

# graphify hook install / git config both act on the current repo. The repo now
# lives externally (e.g. ~/.dotfiles) and deploys into ~/.config by symlink, so
# cd to THIS repo's root — derived from the script's own location (three levels
# up from macos/setup/tweak/), not the old hardcoded ~/.config.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"
# Resolve the launcher explicitly since ~/.local/bin may not be on PATH yet.
graphify_bin="$(command -v graphify || echo "$HOME/.local/bin/graphify")"

# Auto-rebuild the knowledge graph after every commit and branch switch
# (AST-only: code + markdown structure, no LLM / no API cost). Git hooks live in
# .git/hooks and are NOT version-controlled, so this has to run per machine at
# bootstrap. Idempotent — re-running just reports "already installed".
"$graphify_bin" hook install

# graphify-out/graph.json is tracked (see .gitattributes) so the graph travels
# with the repo. Register the union merge-driver so rebuilds on different
# machines compose instead of conflicting. .git/config is not version-controlled,
# so this also has to run per machine at bootstrap.
git config merge.graphify.name "graphify graph.json union merge"
git config merge.graphify.driver "$graphify_bin merge-driver %O %A %B"
