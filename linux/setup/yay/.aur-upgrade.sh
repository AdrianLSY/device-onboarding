#!/bin/bash
# setup/yay/.aur-upgrade.sh
#
# Rebuilds each installed package this directory lists from the AUR when the
# AUR's version is newer than the installed one. `yay -Sua` upgrades only
# packages that no sync repo carries, and pacman follows the repo's build of
# any package a repo does carry. So a package a CachyOS repo also builds
# (claude-desktop, cursor-bin) would otherwise stay on the repo's build, which
# can trail the AUR's by days. pacman -Syu still moves it back to the repo's
# build once that is the newer one, so every run ends on the newer of the two.
#
# Run by this directory's .setup.sh and by fish's `update`. Hidden, so the
# runner never mistakes it for a package.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same as `update`'s `yay -Sua`: build with the system toolchains only, never
# the asdf shims or user-local tools on the caller's PATH.
export PATH=/usr/bin:/bin

PKGS=()
for file in "$DIR"/*.sh; do
    BASENAME="$(basename "$file")"
    [[ "$BASENAME" == .* || ! -f "$file" ]] && continue
    PKG="${BASENAME%.sh}"
    pacman -Q "$PKG" &>/dev/null && PKGS+=("$PKG")
done
(( ${#PKGS[@]} )) || exit 0

echo "Checking the AUR for builds newer than the installed ones..."

# One AUR query for all of them, as "<name> <version>" lines.
mapfile -t AUR < <(LC_ALL=C yay -Sia "${PKGS[@]}" 2>/dev/null \
    | awk -F' *: ' '$1 == "Name" { n = $2 } $1 == "Version" { print n, $2 }')

FAILED=()
UPGRADED=()

for line in "${AUR[@]}"; do
    read -r PKG AUR_VER <<<"$line"
    LOCAL_VER="$(pacman -Q "$PKG" | awk '{ print $2 }')"
    (( $(vercmp "$AUR_VER" "$LOCAL_VER") > 0 )) || continue

    echo "⬆️ $PKG: $LOCAL_VER -> $AUR_VER (AUR)"
    if yay -S --noconfirm --answerclean All --answerdiff None --answeredit None "aur/$PKG"; then
        UPGRADED+=("$PKG")
    else
        FAILED+=("$PKG")
    fi
done

if (( ${#FAILED[@]} )); then
    echo "❌ Failed:   ${FAILED[*]}"
fi
if (( ${#UPGRADED[@]} )); then
    echo "✅ Upgraded: ${UPGRADED[*]}"
fi
if (( ! ${#FAILED[@]} && ! ${#UPGRADED[@]} )); then
    echo "✅ No AUR build is newer than the installed one."
fi

(( ${#FAILED[@]} )) && exit 1 || exit 0
