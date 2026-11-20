#!/bin/bash
set -e

# The OpenCode CLI (`opencode`). In Arch's extra repo, so pacman installs and
# upgrades it, in step with opencode-desktop, which needs this exact version.
sudo pacman -S --noconfirm opencode
