#!/bin/bash
set -e

pacman -Q kitty &>/dev/null && sudo pacman -Rns --noconfirm kitty || true
pacman -Q rofi &>/dev/null && sudo pacman -Rns --noconfirm rofi || true
pacman -Q nano-syntax-highlighting &>/dev/null && sudo pacman -Rns --noconfirm nano-syntax-highlighting || true
pacman -Q nano &>/dev/null && sudo pacman -Rns --noconfirm nano || true

# linux/kitty and linux/rofi left the repo when Alacritty and Vicinae replaced
# them: drop each link only while it still points there and dangles
for app in kitty rofi; do
    if [ -L ~/.config/$app ] && [ ! -e ~/.config/$app ] && [[ "$(readlink ~/.config/$app)" == */linux/$app ]]; then
        rm ~/.config/$app
    fi
done
