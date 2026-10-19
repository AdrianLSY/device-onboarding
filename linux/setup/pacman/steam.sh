#!/bin/bash
set -e

# steam is in [multilib], which CachyOS enables by default.
sudo pacman -S --noconfirm steam
