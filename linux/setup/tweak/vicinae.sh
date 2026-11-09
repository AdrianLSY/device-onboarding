#!/bin/bash
set -e

# Vicinae reads themes only from ~/.local/share/vicinae/themes and the system's
# data dirs, never from ~/.config/vicinae, so link the repo's theme into the
# first. _link_one is idempotent and backs up whatever it replaces. Repo root is
# three levels up (linux/setup/tweak/).
# shellcheck source=lib/link.sh
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$REPO/lib/link.sh"

_link_one "$REPO/linux/vicinae/themes/mac-black.toml" \
    "$HOME/.local/share/vicinae/themes/mac-black.toml" "vicinae theme mac-black"

# uwsm runs Hyprland as a systemd service, so Vicinae's docs start the server
# with the user unit the package ships rather than Hyprland's autostart. It is
# wanted by graphical-session.target and starts at the next login.
systemctl --user is-enabled --quiet vicinae.service || systemctl --user enable vicinae.service
