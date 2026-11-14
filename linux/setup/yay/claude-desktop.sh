#!/bin/bash
set -e

# Not on Flathub. This AUR package repackages Anthropic's official .deb
# (downloads.claude.ai). The cachyos repo carries a build too, which trails the
# AUR's, so this takes the AUR's; .aur-upgrade.sh keeps it on the newer of the two.
yay -S --noconfirm aur/claude-desktop
