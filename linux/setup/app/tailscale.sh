#!/bin/bash
set -e

# On Arch the install script installs the repo's tailscale package, so pacman
# upgrades it from then on.
if command -v tailscale >/dev/null 2>&1; then
    echo "tailscale is pacman's package; pacman upgrades it."
    exit 0
fi
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale set --operator=$USER
