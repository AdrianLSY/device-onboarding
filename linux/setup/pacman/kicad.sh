#!/bin/bash
set -e

# Arch splits KiCad's libraries out of the app (the macOS cask bundles them):
# symbols and footprints, and the 3D models that STEP export to Onshape needs.
sudo pacman -S --noconfirm kicad kicad-library kicad-library-3d
