#!/bin/bash
set -e

# Point Vivaldi's Custom UI Modifications folder at ~/.config/vivaldi-css, the
# linux/vivaldi-css dir setup.sh links there. linux/vivaldi-stable.conf turns
# the feature on; the folder lives only in the profile's Preferences, which a
# running Vivaldi rewrites from memory, so this edits it only while Vivaldi is
# closed. Backups reuse lib/link.sh's _link_backup_path.
# shellcheck source=lib/link.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/lib/link.sh"

PROFILE="$HOME/.config/vivaldi"
PREFS="$PROFILE/Default/Preferences"
DIR="$HOME/.config/vivaldi-css"

if [ ! -f "$PREFS" ]; then
    echo "Vivaldi has no profile yet. Open it once, quit it, then run this tweak again:"
    echo "  $0"
    exit 0
fi

current="$(jq -r '.vivaldi.appearance.css_ui_mods_directory // ""' "$PREFS")"
if [ "$current" = "$DIR" ]; then
    echo "Vivaldi already loads UI mods from $DIR"
    exit 0
fi
# A folder set by hand may hold other mods: leave it for a person to merge.
if [ -n "$current" ]; then
    echo "Vivaldi loads UI mods from $current, not $DIR. Copy $DIR/*.css there,"
    echo "or change the folder in Settings > Appearance > Custom UI Modifications."
    exit 0
fi

# SingletonLock points at <host>-<pid> while Vivaldi runs. A crash leaves it
# behind, so check that the pid is alive.
lock="$(readlink "$PROFILE/SingletonLock" 2>/dev/null || true)"
if [ -n "$lock" ] && kill -0 "${lock##*-}" 2>/dev/null; then
    echo "Vivaldi is running and would overwrite the change. Quit Vivaldi, then run:"
    echo "  $0"
    echo "Or set Settings > Appearance > Custom UI Modifications to $DIR and restart Vivaldi."
    exit 0
fi

backup="$(_link_backup_path "$PREFS")"
cp -p "$PREFS" "$backup"
tmp="$(mktemp "$PREFS.XXXXXX")"
jq -c --arg dir "$DIR" '.vivaldi.appearance.css_ui_mods_directory = $dir' "$PREFS" >"$tmp"
mv "$tmp" "$PREFS"
echo "Vivaldi loads UI mods from $DIR (Preferences backed up to $(basename "$backup"))"
