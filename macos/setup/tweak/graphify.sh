#!/bin/bash
set -e

# The Linux tier runs this file through linux/setup/tweak/graphify.sh, so keep
# it portable.

# NOTE: the double-y is intentional — the PyPI package is `graphifyy`
# (plain `graphify` does not exist on PyPI). Verified 2026-07-02.
# Pinned so a bootstrap never changes how the tracked graph is built:
# .claude/graphify-merge.py imports graphify's internals, and 0.9.92's rebuilds
# drop the graph's LLM-extracted nodes in ways a later release may change (see
# "graphify" in CLAUDE.md). Bump it by hand, after trying the merge script with
# the new version. uv replaces an installed graphifyy of another version.
uv tool install graphifyy==0.9.92

# git rev-parse / git config act on the current repo. The repo lives externally
# (e.g. ~/.dotfiles) and deploys into ~/.config by symlink, so cd to THIS repo's
# root — derived from the script's own location (three levels up from
# macos/setup/tweak/).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"
# Resolve the launcher explicitly since ~/.local/bin may not be on PATH yet.
graphify_bin="$(command -v graphify || echo "$HOME/.local/bin/graphify")"

# No graphify git hooks. `graphify hook install` adds post-commit, post-checkout,
# post-merge and post-rewrite hooks that rebuild graph.json from the AST pass
# alone: after a merge, checkout or rebase that drops about 1,500 of its
# LLM-extracted nodes, and after a commit the nodes of the changed files. Either
# way the smaller graph is left in the working tree for `ghp`'s `git add .` to
# commit. The graph is refreshed by hand with .claude/graphify-merge.py instead.
#
# Bootstraps before 2026-10-22 installed the hooks, so cut graphify's blocks back
# out. Not with `graphify hook uninstall`: it also unregisters the merge driver
# and deletes its line from the tracked .gitattributes. Each block runs from a
# `# graphify-...hook-start` line to its `-end` line; anything else in the hook
# (pre-commit's own hook is a separate file) is kept, and a hook left with only
# its shebang is deleted, as graphify's own uninstall does. A re-run finds no
# blocks and changes nothing.
hooks_dir="$(git rev-parse --git-path hooks)"
for hook in post-commit post-checkout post-merge post-rewrite; do
    f="$hooks_dir/$hook"
    [ -f "$f" ] && grep -q '^# graphify-.*hook-start$' "$f" || continue
    if ! grep -q '^# graphify-.*hook-end$' "$f"; then
        echo "graphify: $f has a graphify block with no end marker; remove it by hand." >&2
        continue
    fi
    rest="$(awk '/^# graphify-.*hook-start$/ { skip = 1 } !skip { print } /^# graphify-.*hook-end$/ { skip = 0 }' "$f")"
    if printf '%s\n' "$rest" | grep -qv -e '^#!' -e '^[[:space:]]*$'; then
        printf '%s\n' "$rest" > "$f"
        echo "graphify: removed graphify's block from $f"
    else
        rm "$f"
        echo "graphify: removed $f (it held only graphify's block)"
    fi
done

# graphify-out/graph.json is tracked (see .gitattributes) so the graph travels
# with the repo. Register the union merge-driver so rebuilds on different
# machines compose instead of conflicting. .git/config is not version-controlled,
# so this also has to run per machine at bootstrap.
git config merge.graphify.name "graphify graph.json union merge"
git config merge.graphify.driver "$graphify_bin merge-driver %O %A %B"
