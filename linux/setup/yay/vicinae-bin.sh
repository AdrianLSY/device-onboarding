#!/bin/bash
set -e

# Not in the Arch or CachyOS repos. Vicinae's install docs recommend this AUR
# package, which repackages the official release build from GitHub.
yay -S --noconfirm vicinae-bin
