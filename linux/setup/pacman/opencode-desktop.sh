#!/bin/bash
set -e

# OpenCode's desktop app. In Arch's extra repo, upgraded by pacman. Flathub's
# ai.opencode.opencode is sandboxed: its agent's shell can't reach the host's
# git, node, uv or docker, so this takes the repo's build.
sudo pacman -S --noconfirm opencode-desktop
