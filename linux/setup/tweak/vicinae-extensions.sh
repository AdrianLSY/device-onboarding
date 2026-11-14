#!/bin/bash
set -e

# Installs the Vicinae extensions that hypr/hyprland.lua's keybinds open, the way
# Vicinae's own store does: download the extension's zip and unpack it into
# ~/.local/share/vicinae/extensions/<id>. An extension already there is left
# alone, so a re-run downloads nothing and the version Vicinae's store updated
# it to stays. Uninstall from Vicinae ("Uninstall Extension"), which also clears
# the extension's stored data.
#
# The server watches that directory only if it existed when the server started,
# which on a new machine it doesn't, so after an install the running server is
# restarted to load the new commands.

EXT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vicinae/extensions"
VICINAE_STORE="https://api.vicinae.com/v1/store"
RAYCAST_STORE="https://backend.raycast.com/api/v1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INSTALLED=""

# _install <id> <zip url>: unpack into a dot-named staging dir, which Vicinae's
# scan skips, and move it into place only once it holds a package.json.
_install() {
    local id="$1" url="$2"
    curl -fsSL -o "$TMP/$id.zip" "$url"
    mkdir "$TMP/$id"
    bsdtar -xf "$TMP/$id.zip" --strip-components 1 -C "$TMP/$id"
    if [ ! -f "$TMP/$id/package.json" ]; then
        echo "🔴 vicinae-extensions: $id's download has no package.json"
        return 1
    fi
    mkdir -p "$EXT_DIR"
    rm -rf "$EXT_DIR/.staging-$id"
    mv "$TMP/$id" "$EXT_DIR/.staging-$id"
    mv "$EXT_DIR/.staging-$id" "$EXT_DIR/$id"
    INSTALLED=1
    echo "🟢 vicinae-extensions: installed $id"
}

# vicinae_ext <author> <name>: an extension from Vicinae's store.
vicinae_ext() {
    local id="store.vicinae.$2"
    [ -d "$EXT_DIR/$id" ] && { echo "⏭️  vicinae-extensions: $id already installed"; return; }
    _install "$id" "$VICINAE_STORE/$1/$2/download"
}

# raycast_ext <author> <name>: an extension from Raycast's store. Its download
# URLs expire, so take the current one from the store's search, as Vicinae's
# "Raycast Store" command does.
raycast_ext() {
    local id="store.raycast.$2" url
    [ -d "$EXT_DIR/$id" ] && { echo "⏭️  vicinae-extensions: $id already installed"; return; }
    url="$(curl -fsSL "$RAYCAST_STORE/store_listings/search?q=$2" |
        jq -r --arg a "$1" --arg n "$2" \
            'first(.data[] | select(.name == $n and .author.handle == $a) | .download_url) // empty')"
    if [ -z "$url" ]; then
        echo "🔴 vicinae-extensions: $1/$2 not found in Raycast's store"
        return 1
    fi
    _install "$id" "$url"
}

# KeePassXC: Vicinae's port, which runs keepassxc-cli (pacman/keepassxc.sh).
# Raycast's own needs patches to run under Vicinae.
vicinae_ext system7 keepassxc
# Bitwarden through rbw (pacman/rbw.sh, configured by tweak/rbw.sh). Raycast's
# Bitwarden extension, built on bw, doesn't work under Vicinae on Linux.
vicinae_ext bl4zee1g bitwarden
# Tailscale: Vicinae's store has none, and Vicinae lists Raycast's as fully
# working. base.jsonc points it at /usr/bin/tailscale.
raycast_ext samlinville tailscale
# Zed's recent projects, from Vicinae's store. It finds ~/.local/bin/zed and
# Zed's database (~/.local/share/zed/db) itself, so it needs no preferences.
vicinae_ext pavle99 zed-recents

# try-restart leaves a stopped server stopped; it loads them when it starts.
if [ -n "$INSTALLED" ]; then
    systemctl --user try-restart vicinae.service
fi
