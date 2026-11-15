#!/bin/bash

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"

# Install Homebrew if not present
if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Apple Silicon installs to /opt/homebrew, Intel to /usr/local.
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

echo "Updating Homebrew..."
brew update || true

echo "Starting brew installs..."

FAILED=()
SUCCESS=()

# Casks that are `auto_updates` but whose own updater lags Homebrew's release (OpenCode
# Desktop never moved a v1 install to v2). When one is already installed, the runner
# upgrades it instead of skipping it. Keep in step with update-schedule.sh.
UPGRADE_INSTALLED=(opencode-desktop)

for file in "$DIR"/*.sh; do
    BASENAME="$(basename "$file")"

    # Skip hidden files, this script itself, and non-regular files
    if [[ "$BASENAME" == .* ]] || [[ "$BASENAME" == "$SELF" ]] || [[ ! -f "$file" ]]; then
        continue
    fi

    PKG="${BASENAME%.sh}"

    if brew list "$PKG" &>/dev/null || brew list --cask "$PKG" &>/dev/null; then
        if [[ " ${UPGRADE_INSTALLED[*]} " == *" $PKG "* ]]; then
            # A named cask is upgraded even with auto_updates; a no-op when current.
            echo "⬆️ $PKG is installed; upgrading to the latest release..."
            if brew upgrade --cask "$PKG"; then
                echo "🟢 $PKG is up to date."
            else
                echo "🔴 $PKG was not upgraded"
                FAILED+=("$PKG")
            fi
            continue
        fi
        echo "⏭️ $PKG is already installed."
        continue
    fi

    LOGFILE="$DIR/$BASENAME.log"
    bash "$file" 2>&1 | tee "$LOGFILE"
    STATUS=${PIPESTATUS[0]}
    if [[ $STATUS -eq 0 ]]; then
        echo "🟢 $PKG installed successfully."
        rm -f "$LOGFILE"
        SUCCESS+=("$PKG")
    else
        echo "🔴 $PKG was not installed"
        cat "$LOGFILE"
        FAILED+=("$PKG")
    fi
done

echo "brew installs complete!"

# Summary
if (( ${#FAILED[@]} )); then
    echo "❌ Failed:   ${FAILED[*]}"
fi
if (( ${#SUCCESS[@]} )); then
    echo "✅ Installed: ${SUCCESS[*]}"
fi

# Exit nonzero if anything failed
(( ${#FAILED[@]} )) && exit 1 || exit 0
