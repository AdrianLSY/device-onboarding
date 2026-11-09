#!/bin/bash
set -e

pacman -Q kitty &>/dev/null && sudo pacman -Rns --noconfirm kitty || true
pacman -Q nano-syntax-highlighting &>/dev/null && sudo pacman -Rns --noconfirm nano-syntax-highlighting || true
pacman -Q nano &>/dev/null && sudo pacman -Rns --noconfirm nano || true

# linux/kitty left the repo when Alacritty replaced kitty: drop the link to it
# only while it still points there and dangles
if [ -L ~/.config/kitty ] && [ ! -e ~/.config/kitty ] && [[ "$(readlink ~/.config/kitty)" == */linux/kitty ]]; then
    rm ~/.config/kitty
fi
