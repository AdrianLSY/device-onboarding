#!/bin/bash
set -e

# Per-app keyd bindings (keyd/app.conf), so far only Cmd+C copying in Alacritty.
# keyd-application-mapper watches window focus through the wlr-foreign-toplevel
# protocol, which Hyprland serves, and applies the bindings of the focused
# window's class with `keyd bind`. It reaches keyd through /var/run/keyd.socket,
# readable only by the keyd group. Repo root is three levels up
# (linux/setup/tweak/).
# shellcheck source=lib/link.sh
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$REPO/lib/link.sh"
DIR="$REPO/linux/setup/tweak/keyd"

# The group takes effect at the next login; the unit's newgrp covers the time before.
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx keyd; then
    sudo usermod -aG keyd "$USER"
fi

_link_one "$DIR/app.conf" "$HOME/.config/keyd/app.conf" "keyd app.conf"
_link_one "$DIR/keyd-application-mapper.service" \
    "$HOME/.config/systemd/user/keyd-application-mapper.service" "keyd-application-mapper.service"

systemctl --user daemon-reload
systemctl --user enable keyd-application-mapper.service

# Starting it needs the Wayland session, so skip outside one (ssh, a tty). A
# running mapper rereads app.conf on the next focus change, so it is left alone.
if systemctl --user show-environment | grep -q '^WAYLAND_DISPLAY='; then
    systemctl --user is-active --quiet keyd-application-mapper.service ||
        systemctl --user start keyd-application-mapper.service
fi
