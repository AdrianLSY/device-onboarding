#!/bin/bash
set -e

# Tolerate the partial state where the plugin was added but the version
# install failed — a bare `plugin add` errors on an already-added plugin.
asdf plugin list | grep -qx "bun" || asdf plugin add bun
asdf install bun latest

VERSION=$(asdf list bun | tr -d ' *' | sort -V | tail -1)
if [[ "$VERSION" =~ ^[0-9] ]]; then
    sed -i "/^bun /d" ~/.tool-versions && echo "bun $VERSION" >> ~/.tool-versions
else
    echo "WARNING: could not resolve installed version for bun, skipping ~/.tool-versions update" >&2
fi
