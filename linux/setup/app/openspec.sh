#!/bin/bash
set -e

# pacman's npm has its global prefix at /usr, which needs root, so install under
# ~/.local instead: the launcher lands in ~/.local/bin, which is on PATH. Running
# it again replaces an older release with the latest.
npm install --global --prefix "$HOME/.local" --no-audit --no-fund @fission-ai/openspec@latest
