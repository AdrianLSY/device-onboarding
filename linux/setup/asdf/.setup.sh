#!/bin/bash
# setup/asdf/.setup.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"

# The scripts below edit ~/.tool-versions with sed -i, which errors if the
# file is missing — and asdf never creates it on install, so a fresh machine
# starts without one. An empty file is valid to asdf.
[ -f "$HOME/.tool-versions" ] || touch "$HOME/.tool-versions"

# Run from $HOME so `asdf current` (which the elixir plugin reads to pick the
# OTP build of the latest Elixir) sees the global versions, not a project's.
cd "$HOME"

# Every script below installs the latest version of its runtime and makes it
# the global one in ~/.tool-versions, so each one runs every time: on a
# bootstrap, and from fish's `update`. Versions a project pins stay installed.
# A plugin knows only the versions its checkout lists (ruby-build, kerl), so
# update the plugins first.
echo "Updating asdf plugins..."
asdf plugin update --all || echo "WARNING: some asdf plugins failed to update" >&2

echo "Starting asdf installs and upgrades..."

FAILED=()
SUCCESS=()

for file in "$DIR"/*.sh; do
    BASENAME="$(basename "$file")"

    # Skip hidden files, this script itself, and non-regular files
    if [[ "$BASENAME" == .* ]] || [[ "$BASENAME" == "$SELF" ]] || [[ ! -f "$file" ]]; then
        continue
    fi

    PKG="${BASENAME%.sh}"

    LOGFILE="$DIR/$BASENAME.log"
    bash "$file" 2>&1 | tee "$LOGFILE"
    STATUS=${PIPESTATUS[0]}
    if [[ $STATUS -eq 0 ]]; then
        echo "🟢 $PKG is installed and up to date."
        rm -f "$LOGFILE"
        SUCCESS+=("$PKG")
    else
        echo "🔴 $PKG was not installed or upgraded"
        cat "$LOGFILE"
        FAILED+=("$PKG")
    fi
done

asdf reshim
echo "asdf installs and upgrades complete!"

# Summary
if (( ${#FAILED[@]} )); then
    echo "❌ Failed:   ${FAILED[*]}"
fi
if (( ${#SUCCESS[@]} )); then
    echo "✅ Up to date: ${SUCCESS[*]}"
fi

# Exit nonzero if anything failed
(( ${#FAILED[@]} )) && exit 1 || exit 0
