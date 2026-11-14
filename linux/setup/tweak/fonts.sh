#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FONT_DIR="$HOME/.local/share/fonts"

mkdir -p "$FONT_DIR"
cp -rf "$DIR"/fonts/* "$FONT_DIR"

# Rebuild font cache
fc-cache

# Inter Medium is the default UI font, as in gtk-3.0/gtk-4.0 settings.ini.
# GTK reads it from gsettings on Wayland (through the settings portal for GTK 4).
gsettings set org.gnome.desktop.interface font-name 'Inter Medium 11'
