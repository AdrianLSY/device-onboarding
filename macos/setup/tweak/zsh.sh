#!/bin/bash
set -e

# Backups reuse lib/link.sh's _link_backup_path (non-colliding <file>.bak.<timestamp>).
# Tweaks run as their own process, so the library is sourced here; it has no
# run-side-effects. Repo root is three levels up (macos/setup/tweak/).
# shellcheck source=lib/link.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/lib/link.sh"

# Point zsh to ~/.config/zsh. Desired ~/.zshenv content (single line).
# shellcheck disable=SC2016  # literal $HOME is intentional — expands at shell startup
ZSHENV_LINE='export ZDOTDIR="$HOME/.config/zsh"'

# Move <file> aside to a non-colliding backup. Never deletes.
backup() {
    local bak
    bak="$(_link_backup_path "$1")"
    mv "$1" "$bak"
    echo "zsh: backed up $1 -> $bak"
}

# Pre-existing user shell config that would shadow the repo's zsh setup is
# BACKED UP, never deleted — same .bak.<timestamp> convention as lib/link.sh.
# (Compiled *.zwc artifacts are regenerable, so plain removal is fine there.)
for f in "$HOME/.zshrc" "$HOME/.zprofile"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        backup "$f"
    fi
done
rm -f "$HOME/.zshrc.zwc"

# Only rewrite ~/.zshenv when its content differs, so a re-run is a no-op. Any
# other content (e.g. a line an installer appended) is backed up first, never
# clobbered.
if [ ! -f "$HOME/.zshenv" ] || [ "$(cat "$HOME/.zshenv")" != "$ZSHENV_LINE" ]; then
    if [ -e "$HOME/.zshenv" ] || [ -L "$HOME/.zshenv" ]; then
        backup "$HOME/.zshenv"
    fi
    printf '%s\n' "$ZSHENV_LINE" > "$HOME/.zshenv"
fi

# Homebrew's shellenv is already sourced by the tracked zsh/.zprofile, so there
# is nothing to append here. (The old append also ran before configs were copied
# into ~/.config, so it failed when ~/.config/zsh did not yet exist.)

# Install zinit
if [[ ! -d "$HOME/.local/share/zinit" ]]; then
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/zdharma-continuum/zinit/HEAD/scripts/install.sh)"
fi
