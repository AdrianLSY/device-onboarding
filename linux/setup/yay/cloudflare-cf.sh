#!/bin/bash
set -e

# Cloudflare's cf CLI. There is no Flatpak or pacman package; this AUR package
# builds from the official npm tarball, pinned by sha256. macOS installs cf with
# npm instead (macos/setup/tweak/cloudflare-cli.sh).
yay -S --noconfirm cloudflare-cf
