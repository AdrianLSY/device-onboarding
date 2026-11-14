#!/bin/bash
set -e

if command -v uv >/dev/null 2>&1; then
    uv self update
else
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
