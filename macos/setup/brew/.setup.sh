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

# An app installed outside Homebrew (the vendor's own download, or a copy
# migrated from an old Mac) is not in `brew list`, and `brew install --cask`
# then refuses with "It seems there is already an App at '/Applications/…'".
# So a cask also counts as installed when every app (or app suite, such as
# KiCad's folder) it would place is already at its target path, which brew's
# JSON gives, honouring any --appdir. The copy there is left as it is: no
# --force and no --adopt, so a user's app is never replaced. Homebrew does not
# manage or update it. Prints the paths it found.
# Only scripts that install a cask are checked: a formula's token can resolve
# to a cask (`docker` names `docker-desktop` through its old token), and that
# app being present says nothing about the formula. Any lookup failure (a cask
# from a tap not added yet, no python3, an older brew without `target`) returns
# 1, so the script runs as before.
cask_apps_present() {
    local file="$1" pkg="$2" targets target
    grep -q -- '--cask' "$file" || return 1
    targets="$(brew info --cask --json=v2 "$pkg" 2>/dev/null | python3 -c '
import json, sys
for cask in json.load(sys.stdin).get("casks", []):
    for artifact in cask.get("artifacts", []):
        if ("app" in artifact or "suite" in artifact) and "target" in artifact:
            print(artifact["target"])
' 2>/dev/null)" || return 1
    [[ -n "$targets" ]] || return 1
    while IFS= read -r target; do
        [[ -e "$target" ]] || return 1
    done <<EOF
$targets
EOF
    printf '%s\n' "$targets"
}

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

    if APPS="$(cask_apps_present "$file" "$PKG")"; then
        echo "⏭️ $PKG is already installed (not through Homebrew), so it is left as it is:"
        printf '%s\n' "$APPS" | sed 's/^/   /'
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
