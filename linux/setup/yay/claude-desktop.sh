#!/bin/bash
set -e

# Not on Flathub. This AUR package repackages Anthropic's official .deb
# (downloads.claude.ai).
yay -S --noconfirm claude-desktop
