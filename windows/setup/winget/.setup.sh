#!/bin/bash

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"

# winget (Windows Package Manager) is required. The top-level setup.sh preflight
# already verified its presence; this guard keeps the module runnable standalone.
if ! command -v winget &>/dev/null; then
    echo "🔴 winget not found on PATH."
    exit 1
fi

echo "Starting winget installs..."

FAILED=()
SUCCESS=()

# Packages upgraded, not skipped, when already installed: nothing else on Windows moves an
# existing install to a newer release (no scheduled update), and OpenCode Desktop's own
# updater did not cross from v1 to v2. T3 Code is here so a re-run moves an install that
# is behind winget's version, including a copy installed by hand if winget recognises it.
# `winget upgrade` exits non-zero when no newer version exists, so only the version
# afterwards says whether it worked.
UPGRADE_INSTALLED=(Anomaly.OpenCode.Desktop T3Tools.T3Code)

for file in "$DIR"/*.sh; do
    BASENAME="$(basename "$file")"

    # Skip hidden files, this script itself, and non-regular files
    if [[ "$BASENAME" == .* ]] || [[ "$BASENAME" == "$SELF" ]] || [[ ! -f "$file" ]]; then
        continue
    fi

    # The filename minus .sh MUST equal the full winget id (e.g. Mozilla.Firefox.sh),
    # so the exact-match skip-check below recognizes an already-installed package.
    # `winget list --id "$PKG" -e` exits 0 when the exact id is installed, non-zero
    # otherwise.
    PKG="${BASENAME%.sh}"

    if winget list --id "$PKG" -e &>/dev/null; then
        if [[ " ${UPGRADE_INSTALLED[*]} " == *" $PKG "* ]]; then
            echo "⬆️ $PKG is installed; upgrading to the latest release..."
            winget upgrade --id "$PKG" -e --accept-package-agreements --accept-source-agreements || \
                echo "ℹ️ winget reported nothing to upgrade for $PKG (or the upgrade failed); check 'winget list --id $PKG -e'."
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

echo "winget installs complete!"

# Summary
if (( ${#FAILED[@]} )); then
    echo "❌ Failed:   ${FAILED[*]}"
fi
if (( ${#SUCCESS[@]} )); then
    echo "✅ Installed: ${SUCCESS[*]}"
fi

# Exit nonzero if anything failed
(( ${#FAILED[@]} )) && exit 1 || exit 0
