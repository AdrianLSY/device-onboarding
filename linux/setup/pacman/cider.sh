#!/bin/bash
set -eo pipefail

# Apple Music client. Not in the Arch repos; Cider Collective ships its own
# signed pacman repo (https://repo.cider.sh). The app needs a license bought
# from cider.sh before it will play.
KEY_ID="A0CD6B993438E22634450CDD2A236C3F42A61682"
SERVER="https://repo.cider.sh/arch/x64"
# Up to 4.0.9.1 the repo was /arch itself. That database is still served but
# stopped there; newer builds are only in /arch/x64.
OLD_SERVER="https://repo.cider.sh/arch"
CONF=/etc/pacman.conf

# _link_backup_path, for the backup name.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/link.sh"

# Only the pinned fingerprint is locally signed, so if the URL ever serves a
# different key, lsign fails and nothing from the repo is trusted.
curl -fsSL https://repo.cider.sh/ARCH-GPG-KEY | sudo pacman-key --add -
sudo pacman-key --lsign-key "$KEY_ID"

if ! grep -q '^\[cidercollective\]' "$CONF"; then
    sudo tee -a "$CONF" >/dev/null <<EOF

# Cider Collective Repository
[cidercollective]
SigLevel = Required TrustedOnly
Server = $SERVER
EOF
elif grep -qxF "Server = $OLD_SERVER" "$CONF"; then
    BACKUP="$(_link_backup_path "$CONF")"
    sudo cp -p "$CONF" "$BACKUP"
    sudo sed -i "s#^Server = $OLD_SERVER\$#Server = $SERVER#" "$CONF"
    echo "cider: [cidercollective] now uses $SERVER (old $CONF kept as $BACKUP)"
fi

# -Syu rather than -Sy then -S: syncing the new repo's database without
# upgrading would be a partial upgrade. The runner just ran -Syyu, so this
# upgrades nothing else.
sudo pacman -Syu --noconfirm cider
