#!/bin/bash
set -e

# Erlang first, at its latest version too: Elixir builds against the newest
# installed OTP. Same partial-state guard as elixir below.
asdf plugin list | grep -qx "erlang" || asdf plugin add erlang
asdf install erlang latest

VERSION=$(asdf list erlang | tr -d ' *' | sort -V | tail -1)
if [[ "$VERSION" =~ ^[0-9] ]]; then
    sed -i "/^erlang /d" ~/.tool-versions && echo "erlang $VERSION" >> ~/.tool-versions
else
    echo "WARNING: could not resolve installed version for erlang, skipping ~/.tool-versions update" >&2
fi

# Elixir requires a compatible Erlang/OTP installation
OTP_VERSION=$(asdf list erlang 2>/dev/null | tr -d ' *' | sort -V | tail -1 | cut -d. -f1)
if [[ -z "$OTP_VERSION" ]] || ! [[ "$OTP_VERSION" =~ ^[0-9]+$ ]]; then
    echo "ERROR: no erlang version installed via asdf, cannot install elixir" >&2
    exit 1
fi

export ELIXIR_OTP_RELEASE="$OTP_VERSION"

# Same partial-state guard as erlang above.
asdf plugin list | grep -qx "elixir" || asdf plugin add elixir
asdf install elixir latest

VERSION=$(asdf list elixir | tr -d ' *' | sort -V | tail -1)
if [[ "$VERSION" =~ ^[0-9] ]]; then
    sed -i "/^elixir /d" ~/.tool-versions && echo "elixir $VERSION" >> ~/.tool-versions
else
    echo "WARNING: could not resolve installed version for elixir, skipping ~/.tool-versions update" >&2
fi
