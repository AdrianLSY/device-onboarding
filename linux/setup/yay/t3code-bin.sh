#!/bin/bash
set -e

# T3 Code's desktop app. Not on Flathub, and upstream ships no Flatpak. T3 Code's README
# and docs/user/install.md name this AUR package for Arch (`yay -S t3code-bin`); the
# maintainer is a community member, not T3 Tools. It repackages the official AppImage from
# github.com/pingdotgg/t3code releases, pinned by sha256 in its PKGBUILD. x86_64 only. The
# package carries no AUR-side updater: T3 Code's README says to update an AUR install with
# the AUR helper (yay -Syyu in the runner, yay -Sua in fish `update`), not the in-app updater.
yay -S --noconfirm aur/t3code-bin
