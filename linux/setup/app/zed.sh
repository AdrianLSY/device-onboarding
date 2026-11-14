#!/bin/bash
set -e

# Zed updates itself while it runs. The install script also upgrades, but
# downloads the whole release every time, so skip it when the installed version
# is already the latest stable one. If the release API can't be read, reinstall.
if command -v zed >/dev/null 2>&1; then
    LATEST="$(curl -fsSL 'https://zed.dev/api/releases/latest?asset=zed&os=linux&arch=x86_64' | jq -r .version 2>/dev/null || true)"
    CURRENT="$(zed --version | awk '{ print $2 }')"
    if [[ -n "$LATEST" && "$CURRENT" == "$LATEST" ]]; then
        echo "zed $CURRENT is the latest release."
        exit 0
    fi
fi
curl -fsSL https://zed.dev/install.sh | sh
fish -c 'fish_add_path -U ~/.local/bin' || true
