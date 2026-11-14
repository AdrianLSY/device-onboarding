#!/bin/bash
set -e

# Timescale's Tiger CLI. Named tiger.sh, not tiger-cli.sh, after the command it
# installs. Installs to ~/.local/bin.
if command -v tiger >/dev/null 2>&1; then
    tiger upgrade
else
    curl -fsSL https://cli.tigerdata.com | sh
fi
