#!/bin/bash
set -e

# SwayNC is the notification daemon (config in linux/swaync/). Its package ships
# a user unit wanted by graphical-session.target, which uwsm starts with
# Hyprland, so enabling it starts SwayNC at the next login. Until then a
# notification starts it through D-Bus activation.
systemctl --user is-enabled --quiet swaync.service || systemctl --user enable swaync.service
