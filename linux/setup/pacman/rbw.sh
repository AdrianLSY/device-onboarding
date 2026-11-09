#!/bin/bash
set -e

# The Bitwarden CLI that Vicinae's "Bitwarden (rbw)" extension runs.
# tweak/rbw.sh points it at the group's Vaultwarden.
sudo pacman -S --noconfirm rbw
