#!/bin/bash
set -e

# Tolerate the partial state where the plugin was added but the version
# install failed — a bare `plugin add` errors on an already-added plugin.
asdf plugin list | grep -qx "ruby" || asdf plugin add ruby
asdf install ruby latest

VERSION=$(asdf list ruby | tr -d ' *' | sort -V | tail -1)
if [[ "$VERSION" =~ ^[0-9] ]]; then
    sed -i "/^ruby /d" ~/.tool-versions && echo "ruby $VERSION" >> ~/.tool-versions
else
    echo "WARNING: could not resolve installed version for ruby, skipping ~/.tool-versions update" >&2
fi
