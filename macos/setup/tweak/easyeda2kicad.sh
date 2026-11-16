#!/bin/bash
set -e

# easyeda2kicad tweak: installs easyeda2kicad, pinned to VERSION, as a uv tool.
# The kicad-design skill (hardware-skills) runs it to take a part's symbol,
# footprint and 3D model from LCSC into a KiCad library:
#   easyeda2kicad --full --lcsc_id=C<number> --output <folder>/<library>
# The folder given to --output must already exist. Without --output it writes to
# ~/Documents/Kicad/easyeda2kicad/, which it creates.
#
# SHARED ACROSS TIERS: this file is the canonical script. The Windows tier runs it
# through windows/setup/tweak/easyeda2kicad.sh, a two-line exec wrapper (a symlink
# would not survive the USB copy that provisions Windows), so it must stay
# portable to Git Bash/MSYS and to macOS's bash 3.2.
#
# What it does, in order:
#   1. Finds uv the way graphify.sh does. On a fresh Windows machine winget
#      installs uv in this same bootstrap and only a new shell sees it, so a
#      missing uv skips the tweak (exit 0) and the next bootstrap offers it again.
#   2. Changes nothing when uv already holds VERSION pinned with ==VERSION, the
#      pin that keeps `uv tool upgrade` from moving it. Otherwise `uv tool
#      install` installs it, or replaces another version or an unpinned copy. A
#      failed installation exits 1, so the runner lists the tweak as failed; one cause
#      is an easyeda2kicad that uv did not install (pip, pipx) in uv's bin folder.
#   3. Checks the installed command starts and reports VERSION.
#   4. Makes sure uv's bin folder (~/.local/bin) is on PATH for new shells. On
#      macOS the zsh config does that (the last lines of macos/zsh/.zshrc), so
#      this tweak writes no shell file. On Windows it runs `uv tool update-shell`,
#      which adds the folder to the user's PATH when it is missing (untested on
#      a real Windows machine).
#
# `--remove` (run by hand) uninstalls it. The libraries it wrote are left alone.
#
# Pin bump: change VERSION after reading the release notes
# (https://github.com/uPesy/easyeda2kicad.py/releases), then fetch one part with
# the kicad-design skill's command to check it still works.

VERSION="1.0.1"
PKG="easyeda2kicad"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *) OS=other ;;
esac

# --- Resolve uv ----------------------------------------------------------------
UV=""
for c in uv uv.exe "$HOME/.local/bin/uv" "$HOME/.local/bin/uv.exe"; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then UV="$c"; break; fi
done

# What uv has installed, such as "v1.0.1 [required: ==1.0.1]"; empty when nothing.
installed() {
    "$UV" tool list --show-version-specifiers 2>/dev/null | tr -d '\r' \
        | sed -n "s/^$PKG //p" | head -n 1
}

# --- --remove ------------------------------------------------------------------
if [ "${1:-}" = "--remove" ]; then
    if [ -z "$UV" ]; then
        echo "❌ easyeda2kicad: uv not found, so it cannot be removed."
        exit 1
    fi
    if [ -z "$(installed)" ]; then
        echo "✅ easyeda2kicad: uv has no easyeda2kicad installed; nothing to remove."
        exit 0
    fi
    "$UV" tool uninstall "$PKG"
    echo "✅ easyeda2kicad: removed. The KiCad libraries it wrote are left as they are."
    exit 0
fi

if [ -z "$UV" ]; then
    echo "⏭️  easyeda2kicad: uv is not on this session's PATH yet (winget-installed tools"
    echo "    need a new shell). Skipping; it will be offered again on the next bootstrap."
    exit 0
fi

# --- Install (only when VERSION is not already installed and pinned) ------------
want="v$VERSION [required: ==$VERSION]"
have="$(installed)"
changed=""
if [ "$have" != "$want" ]; then
    old="${have%% *}"
    old="${old#v}"
    if [ -z "$have" ]; then
        echo "🔧 easyeda2kicad: installing $VERSION."
    elif [ "$old" = "$VERSION" ]; then
        echo "🔧 easyeda2kicad: pinning the installed $VERSION to ==$VERSION."
    else
        echo "🔧 easyeda2kicad: replacing $old with $VERSION."
    fi
    if ! "$UV" tool install "$PKG==$VERSION"; then
        echo "❌ easyeda2kicad: uv could not install $VERSION (see the message above)."
        exit 1
    fi
    changed=1
fi

# --- Check the command starts --------------------------------------------------
bindir="$("$UV" tool dir --bin 2>/dev/null | tr -d '\r')"
if [ "$OS" = windows ] && [ -n "$bindir" ]; then bindir="$(cygpath -u "$bindir")"; fi
exe=""
for c in "$bindir/$PKG" "$bindir/$PKG.exe"; do
    if [ -n "$bindir" ] && [ -x "$c" ]; then exe="$c"; break; fi
done
if [ -z "$exe" ]; then
    where="$bindir"
    [ -n "$where" ] || where="uv's bin folder"
    echo "❌ easyeda2kicad: uv reports $VERSION installed, but there is no $PKG in $where."
    exit 1
fi
set +e
banner="$("$exe" --help 2>&1 | tr -d '\r' | head -n 1)"
set -e
case "$banner" in
    *"v$VERSION "*) ;;
    *)
        echo "❌ easyeda2kicad: $exe did not report $VERSION. It printed:"
        echo "    ${banner:-nothing}"
        exit 1 ;;
esac

# --- PATH (Windows) ------------------------------------------------------------
path_note=""
if [ "$OS" = windows ]; then
    # Idempotent: uv reports when the folder is already on the user's PATH.
    if ! "$UV" tool update-shell; then
        path_note="⚠️  easyeda2kicad: could not add $bindir to your PATH; add it by hand."
    fi
fi

if [ -n "$changed" ]; then
    echo "✅ easyeda2kicad: $VERSION installed at $exe."
    echo "    New terminals and Claude sessions find it as \`$PKG\`."
else
    echo "✅ easyeda2kicad: $VERSION already installed; nothing changed."
fi
if [ -n "$path_note" ]; then echo "$path_note"; fi
