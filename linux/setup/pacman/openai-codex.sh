#!/bin/bash
set -e

# OpenAI's Codex CLI (`codex`), the ChatGPT terminal client and the agent T3 Code
# can drive, from the official `extra` repo, so pacman installs and upgrades it.
# The desktop app is yay/chatgpt-desktop.sh.
sudo pacman -S --noconfirm openai-codex
