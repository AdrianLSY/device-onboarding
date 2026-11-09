#!/bin/bash
set -e

# Point rbw, the Bitwarden CLI behind Vicinae's "Bitwarden (rbw)" extension, at
# the group's Vaultwarden and the account the Bitwarden desktop app signs in
# with. The server is the one bitwarden-server.sh gives bw. rbw keeps its own
# config (~/.config/rbw/config.json), written with `rbw config set`.
#
# A key that is unset is set. A key already set to something else is left
# alone, because rbw's login belongs to that server and email, and this tweak
# never logs anyone out: it prints what to run instead and exits 0. A re-run
# changes nothing. `rbw login` and `rbw unlock` stay with you.

BASE_URL="https://vault.rooftop.my"
EMAIL="adrian@rooftop.my"

if ! command -v rbw >/dev/null 2>&1; then
    echo "⏭️  rbw: rbw is not on PATH, skipping. It installs in the pacman phase."
    exit 0
fi

# `rbw config show` fails until the config file exists, which reads as unset.
CONFIG="$(rbw config show 2>/dev/null || echo '{}')"

for pair in "base_url=$BASE_URL" "email=$EMAIL"; do
    key="${pair%%=*}"
    want="${pair#*=}"
    have="$(jq -r --arg k "$key" '.[$k] // empty' <<<"$CONFIG")"
    if [ "$have" = "$want" ]; then
        echo "⏭️  rbw: $key is already $want."
    elif [ -z "$have" ]; then
        rbw config set "$key" "$want"
        echo "🟢 rbw: set $key to $want."
    else
        echo "⚠️  rbw: $key is $have, so it is unchanged. To move it, run:"
        echo "    rbw config set $key $want && rbw stop-agent"
    fi
done
