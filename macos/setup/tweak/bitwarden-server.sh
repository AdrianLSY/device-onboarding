#!/bin/bash
set -e

# Point the Bitwarden CLI (`bw`) at the group's self-hosted Vaultwarden. bw
# starts out on Bitwarden's cloud, so without this tweak, `bw login` signs in
# there. The desktop app keeps its own server setting, picked on its login
# screen.
#
# Runs on macOS, Linux and Git Bash. The canonical copy is
# Rooftop-Energy-Tech/Device-Onboarding's macos/setup/tweak/bitwarden-server.sh,
# and AdrianLSY/device-onboarding's is byte-identical: fix the Rooftop copy
# first, then copy it across. Each repo's other tier (Windows at Rooftop, Linux
# in the personal repo) runs this file through a 2-line exec wrapper.
#
# bw refuses to change its server while an account is logged in, locked or
# not. This tweak never logs anyone out: in that case it prints what to run
# and exits 0. A bw already on the server is left alone, so a re-run changes
# nothing.

SERVER="https://vault.rooftop.my"

# --- Resolve bw (Git Bash may expose it as bw or bw.exe) ---------------------
BW=""
for c in bw bw.exe; do
    if command -v "$c" >/dev/null 2>&1; then
        BW="$c"
        break
    fi
done
if [ -z "$BW" ]; then
    echo "⏭️  bitwarden-server: bw is not on PATH, skipping. It installs in the"
    echo "    package phase, and this tweak is offered again on the next run."
    exit 0
fi

# --- Already there? -----------------------------------------------------------
# With no URL, `bw config server` prints the current one (https://bitwarden.com
# for the cloud). On first use bw also creates its data file and says so on
# stderr, which is dropped here.
CURRENT="$("$BW" config server 2>/dev/null | tr -d '\r')"
if [ "$CURRENT" = "$SERVER" ]; then
    echo "⏭️  bitwarden-server: bw already uses $SERVER."
    exit 0
fi

# --- Set it --------------------------------------------------------------------
if OUT="$("$BW" config server "$SERVER" 2>&1)"; then
    echo "🟢 bitwarden-server: bw now uses $SERVER (was ${CURRENT:-unknown})."
    exit 0
fi

case "$OUT" in
    *"Logout required"*)
        echo "⚠️  bitwarden-server: bw is logged in to $CURRENT, so its server is unchanged."
        echo "    To move it, run: bw logout && bw config server $SERVER"
        exit 0
        ;;
esac

echo "🔴 bitwarden-server: \`bw config server $SERVER\` failed:"
echo "$OUT"
exit 1
