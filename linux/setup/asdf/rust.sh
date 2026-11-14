#!/bin/bash
set -e

# Tolerate the partial state where the plugin was added but the version
# install failed — a bare `plugin add` errors on an already-added plugin.
asdf plugin list | grep -qx "rust" || asdf plugin add rust
asdf install rust latest

VERSION=$(asdf list rust | tr -d ' *' | sort -V | tail -1)
if [[ "$VERSION" =~ ^[0-9] ]]; then
    sed -i "/^rust /d" ~/.tool-versions && echo "rust $VERSION" >> ~/.tool-versions
else
    echo "WARNING: could not resolve installed version for rust, skipping ~/.tool-versions update" >&2
fi
