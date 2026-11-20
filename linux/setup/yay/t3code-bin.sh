#!/bin/bash
set -e

# T3 Code (pingdotgg/t3code). Not on Flathub, and upstream ships no Flatpak.
# This AUR package repackages the official release AppImage from GitHub.
yay -S --noconfirm aur/t3code-bin
