#!/bin/bash
set -e

if command -v opencode >/dev/null 2>&1; then
    opencode upgrade
else
    curl -fsSL https://opencode.ai/install | bash
fi
