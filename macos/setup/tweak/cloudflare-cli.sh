#!/bin/bash
set -e

# cloudflare-cli tweak: installs `cf`, Cloudflare's own CLI for the whole public
# Cloudflare API (zones, DNS, storage, security settings) and for Workers.
#
# WHY A TWEAK AND NOT A PACKAGE. cf ships only on npm (`npm install -g cf`; its
# GitHub releases carry no binaries). No Homebrew formula or Cloudflare tap entry
# installs it, and the Homebrew formula named `cf` is an unrelated timestamp
# filter. No winget id installs it either (checked 2026-11-02). So it is installed
# with the npm of the Node.js the package phase already put down (brew/node.sh on
# macOS, winget/OpenJS.NodeJS.LTS.sh on Windows). The personal repo's Linux tier
# uses the AUR package `cloudflare-cf` instead (its yay/cloudflare-cf.sh).
#
# SHARED ACROSS TIERS AND REPOS: this file is byte-identical in Rooftop's
# Device-Onboarding and the personal repo, and fixed in Rooftop's first. Rooftop's
# windows/setup/tweak/cloudflare-cli.sh is a 2-line exec wrapper of it, so it must
# stay portable to Git Bash. Node is probed where lib/mcp/common.sh probes it: on
# a fresh Windows box the winget-installed Node is not on this session's PATH yet.
#
# Runs every bootstrap. `npm install -g cf@latest` is idempotent and moves an
# older beta to the current one; nothing else upgrades it.

NODE=""
case "$(uname -s)" in
    Darwin)
        for c in /opt/homebrew/opt/node/bin/node /usr/local/opt/node/bin/node; do
            if [ -x "$c" ]; then NODE="$c"; break; fi
        done
        ;;
    MINGW*|MSYS*|CYGWIN*)
        c="/c/Program Files/nodejs/node.exe"
        if [ -x "$c" ]; then NODE="$c"; fi
        ;;
esac
if [ -z "$NODE" ]; then
    NODE="$(command -v node 2>/dev/null || true)"
fi
if [ -z "$NODE" ]; then
    echo "⏭️  cloudflare-cli: Node.js is not installed yet. Skipping; it'll be offered"
    echo "    again on the next bootstrap."
    exit 0
fi

# npm sits beside node in all three layouts, and npm finds node on PATH.
NODE_DIR="$(dirname "$NODE")"
export PATH="$NODE_DIR:$PATH"
NPM="$NODE_DIR/npm"
if [ ! -x "$NPM" ]; then
    NPM="$(command -v npm 2>/dev/null || true)"
fi
if [ -z "$NPM" ]; then
    echo "🔴 cloudflare-cli: found node at $NODE but no npm beside it." >&2
    exit 1
fi

# npm 11 may warn that workerd's postinstall was not run. Leave it unrun: it only
# downloads the workerd binary when npm failed to install the platform package
# (@cloudflare/workerd-<os>-<arch>), which npm does install.
echo "cloudflare-cli: installing cf with npm…"
"$NPM" install --global --no-audit --no-fund cf@latest

# The launcher lands in <prefix>/bin on macOS and in <prefix> itself on Windows
# (%APPDATA%\npm, which a new shell has on PATH). Check it there rather than
# trusting a bare `cf`, which this session may not see yet.
PREFIX="$("$NPM" prefix --global | tr -d '\r')"
if command -v cygpath >/dev/null 2>&1; then
    PREFIX="$(cygpath -u "$PREFIX")"
fi
CF=""
for c in "$PREFIX/bin/cf" "$PREFIX/cf"; do
    if [ -f "$c" ]; then CF="$c"; break; fi
done
if [ -z "$CF" ]; then
    echo "🔴 cloudflare-cli: npm reported success but no cf launcher is under $PREFIX." >&2
    exit 1
fi

ver="$("$CF" --version 2>/dev/null | tr -d '\r' | head -n 1)"
echo "🟢 cloudflare-cli: cf installed (${ver:-version unknown}, $CF)."
echo "    Sign in with 'cf auth login' when you need it. 'cloudflare' is the same command."
