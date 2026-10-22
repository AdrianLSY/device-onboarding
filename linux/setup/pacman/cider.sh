#!/bin/bash
set -eo pipefail

# Apple Music client. Not in the Arch repos; Cider Collective ships its own
# signed pacman repo (https://repo.cider.sh). The app needs a license bought
# from cider.sh before it will play.
KEY_ID="A0CD6B993438E22634450CDD2A236C3F42A61682"

# Only the pinned fingerprint is locally signed, so if the URL ever serves a
# different key, lsign fails and nothing from the repo is trusted.
curl -fsSL https://repo.cider.sh/ARCH-GPG-KEY | sudo pacman-key --add -
sudo pacman-key --lsign-key "$KEY_ID"

if ! grep -q '^\[cidercollective\]' /etc/pacman.conf; then
    sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

# Cider Collective Repository
[cidercollective]
SigLevel = Required TrustedOnly
Server = https://repo.cider.sh/arch
EOF
fi

# -Syu rather than -Sy then -S: syncing the new repo's database without
# upgrading would be a partial upgrade. The runner just ran -Syyu, so this
# upgrades nothing else.
sudo pacman -Syu --noconfirm cider
