#!/bin/bash
set -e

# Not on Flathub. This AUR package repackages OpenAI's official .deb
# (persistent.oaistatic.com).
yay -S --noconfirm chatgpt-desktop
