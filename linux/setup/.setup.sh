#!/bin/bash

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"

# Modules run as SIBLING processes, so the PATH the app module sets for its
# user-local installs never reaches the tweak module. On a fresh machine fish's
# fish_add_path skips ~/.local/bin while it does not exist yet, so the shell
# that ran setup.sh lacks it, and tweaks that call those installs (graphify.sh
# runs uv) would fail. Same job as the macOS runner's ensure_brew_path.
export PATH="$HOME/.local/bin:$PATH"

echo "Starting setup for all modules..."

ORDER=(
    pacman
    yay
    flatpak
    app
    asdf
    tweak
)

FAILED=()
SUCCESS=()
SKIPPED=()

for BASENAME in "${ORDER[@]}"; do
    SUBDIR="$DIR/$BASENAME"
    SETUP_SH="$SUBDIR/.setup.sh"

    if [[ ! -d "$SUBDIR" ]]; then
        echo "⏭️  $BASENAME: Directory not found. Skipping."
        continue
    fi

    if [[ -x "$SETUP_SH" ]]; then
        echo "Running $SETUP_SH..."
        LOGFILE="$SUBDIR/.setup.sh.log"
        "$SETUP_SH" 2>&1 | tee "$LOGFILE"
        STATUS=${PIPESTATUS[0]}
        if [[ $STATUS -eq 0 ]]; then
            echo "🟢 $BASENAME setup completed successfully."
            rm -f "$LOGFILE"
            SUCCESS+=("$BASENAME")
        else
            echo "🔴 $BASENAME setup failed."
            cat "$LOGFILE"
            FAILED+=("$BASENAME")
        fi
    elif [[ -f "$SETUP_SH" ]]; then
        echo "⏭️  $BASENAME: .setup.sh is not executable. Skipping."
        SKIPPED+=("$BASENAME")
    else
        echo "⏭️  $BASENAME: No .setup.sh found. Skipping."
        SKIPPED+=("$BASENAME")
    fi
done

echo "All module setups complete!"

# Summary
if (( ${#FAILED[@]} )); then
    echo "❌ Failed:   ${FAILED[*]}"
fi
if (( ${#SUCCESS[@]} )); then
    echo "✅ Installed: ${SUCCESS[*]}"
fi

(( ${#FAILED[@]} )) && exit 1 || exit 0
