#!/bin/bash
set -e

# Install ssh-keypick: automatic per-host SSH key selection.
# Auto-discovered and failure-isolated by setup/tweak/.setup.sh, so a hiccup
# here never aborts the rest of the bootstrap.
#
# The helper lives at bin/ssh-keypick and is executed by OpenSSH Match exec (by
# absolute path), not sourced. On connect it probes/caches the right key per
# host, and excludes hosts you've already pinned an IdentityFile for (and
# github.com) so it never disturbs the per-repo git account selection in
# rc.d/git-multi-account.zsh.
#
# Excluding github.com means keypick offers it no key at all, and that wrapper
# only runs in an interactive zsh. The sibling git-multi-account.sh tweak covers
# git run anywhere else: a github.com Host stanza outside the managed block
# (which `install` preserves) plus a git includeIf for personal repos. The
# wrapper still stamps identity and signing onto each repo at clone time.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"

# Stable home after the bootstrap copies configs into ~/.config. The Match exec
# stanzas reference this path so they keep working after a clone dir is removed.
CANONICAL="$HOME/.config/bin/ssh-keypick"

# tweak runs BEFORE configs are copied to ~/.config, so use the in-tree copy now
# (falls back to the canonical path on an in-place re-run from ~/.config).
SRC="$REPO_ROOT/bin/ssh-keypick"
[ -f "$SRC" ] || SRC="$CANONICAL"
if [ ! -f "$SRC" ]; then
    echo "ssh-keypick: helper not found in $REPO_ROOT/bin or ~/.config/bin; skipping"
    exit 0
fi
chmod +x "$SRC" 2>/dev/null || true   # Match exec runs it by path; must be executable

# Expose on PATH via a stable symlink to the ~/.config copy (so you can type
# `ssh-keypick`). The Match exec uses the absolute path, so this is convenience only.
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$CANONICAL" "$BIN_DIR/ssh-keypick"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "ssh-keypick: add '$BIN_DIR' to your PATH to call it by name" ;;
esac

# Ensure ~/.ssh exists with safe perms (a clean Mac may not have it yet).
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# Generate the Match exec block + exclusions only if private keys exist. On a
# fresh machine with no keys yet, skip (an empty block is useless) and tell the
# user to re-run once they've added their keys.
has_private_keys() {
    local f
    for f in "$HOME"/.ssh/*; do
        [ -f "$f" ] || continue
        case "$f" in *.pub) continue ;; esac
        head -n 1 "$f" 2>/dev/null | grep -q "PRIVATE KEY" && return 0
    done
    return 1
}

if has_private_keys; then
    if KEYPICK_BIN="$CANONICAL" "$SRC" install; then
        echo "🟢 ssh-keypick installed; connect to a host and it learns the key."
    else
        echo "ssh-keypick: install step failed (non-fatal); run it later via: ssh-keypick install"
    fi
else
    echo "ssh-keypick: symlinked to $BIN_DIR/ssh-keypick."
    echo "ssh-keypick: no SSH keys yet — after adding keys to ~/.ssh run: ssh-keypick install"
fi
