#!/bin/bash
set -e

# Timescale's Tiger CLI. Named tiger.sh, not tiger-cli.sh, because the runner's
# skip-check is `command -v` on the filename. Installs to ~/.local/bin.
curl -fsSL https://cli.tigerdata.com | sh
