#!/bin/bash
set -e

# Claude Code's native install, which also updates itself in the background.
if command -v claude >/dev/null 2>&1; then
    claude update
else
    curl -fsSL https://claude.ai/install.sh | bash
fi
