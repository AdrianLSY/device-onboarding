#!/bin/bash
set -e

# Nemo's "Open in Terminal" runs exec; "Run in Terminal" adds exec-arg, and
# Alacritty takes its command only after -e
gsettings set org.cinnamon.desktop.default-applications.terminal exec alacritty
gsettings set org.cinnamon.desktop.default-applications.terminal exec-arg "'-e'"
