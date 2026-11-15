#!/bin/bash
set -e

# OpenCode's desktop app. The official `extra/opencode-desktop` exists, but it depends on
# the pacman `opencode` package pinned to its own version, which would put a second
# `opencode` in /usr/bin beside the one app/opencode.sh installs in ~/.opencode/bin and
# make that script's `command -v opencode` + `opencode upgrade` act on the pacman copy
# (pacman runs before app). The AUR package repackages the same upstream .deb with its own
# CLI bundled inside the app, so the terminal client stays app/opencode.sh's alone.
yay -S --noconfirm aur/opencode-desktop-bin
