#!/bin/bash
set -e

# OpenAI's Codex desktop app, the same one macOS runs as com.openai.codex (this build's
# package.json is openai-codex-electron, productName Codex, and it handles codex://).
# Not on Flathub. This AUR package repackages OpenAI's official .deb
# (persistent.oaistatic.com).
yay -S --noconfirm chatgpt-desktop
