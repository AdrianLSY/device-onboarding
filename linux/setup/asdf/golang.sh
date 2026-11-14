#!/bin/bash
set -e

# Tolerate the partial state where the plugin was added but the version
# install failed — a bare `plugin add` errors on an already-added plugin.
asdf plugin list | grep -qx "golang" || asdf plugin add golang
asdf install golang latest

VERSION=$(asdf list golang | tr -d ' *' | sort -V | tail -1)
if [[ "$VERSION" =~ ^[0-9] ]]; then
    sed -i "/^golang /d" ~/.tool-versions && echo "golang $VERSION" >> ~/.tool-versions
else
    echo "WARNING: could not resolve installed version for golang, skipping ~/.tool-versions update" >&2
fi
