#!/bin/bash
set -e

# Use Sill's official tap and trust it so Homebrew can load its cask.
brew tap saffsanity/sill
brew trust --tap saffsanity/sill

brew install --cask saffsanity/sill/sill
