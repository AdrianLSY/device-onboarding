#!/bin/bash
# setup/app/.setup.sh

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"

# Every script below installs its tool or upgrades it to the latest release, so
# each one runs every time: on a bootstrap, and from fish's `update`. They drop
# binaries into user-local dirs (~/.local/bin for zed/claude/zoxide/openspec,
# ~/.pulumi/bin, ~/.opencode/bin) that a non-login bash won't have on PATH;
# without this a script's `command -v` misses its tool and reinstalls it.
# Matches the interactive-shell PATH fish sets.
export PATH="$HOME/.local/bin:$HOME/.pulumi/bin:$HOME/.opencode/bin:$PATH"

echo "Starting generic app installs and upgrades..."

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

echo "App installs and upgrades complete!"

# Summary
if (( ${#FAILED[@]} )); then
    echo "❌ Failed:   ${FAILED[*]}"
fi
if (( ${#SUCCESS[@]} )); then
    echo "✅ Up to date: ${SUCCESS[*]}"
fi

# Exit nonzero if anything failed
(( ${#FAILED[@]} )) && exit 1 || exit 0
