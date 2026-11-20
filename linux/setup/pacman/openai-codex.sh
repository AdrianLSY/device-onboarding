#!/bin/bash
set -e

# OpenAI's Codex CLI (`codex`), the terminal agent T3 Code can drive. In Arch's
# extra repo, so pacman installs and upgrades it. The Codex desktop app is
# yay/chatgpt-desktop.sh.
sudo pacman -S --noconfirm openai-codex
