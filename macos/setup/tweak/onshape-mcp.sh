#!/bin/bash
set -e

# onshape-mcp tweak: registers Onshape's FeatureScript MCP server as `onshape` in
# Claude Code (user scope), so Claude can build parts in a person's Onshape documents as FeatureScript custom features.
#
# SHARED ACROSS TIERS: this file is the canonical script. The Windows tier runs it
# through windows/setup/tweak/onshape-mcp.sh, a two-line exec wrapper, so it must
# stay portable to Git Bash/MSYS and to macOS's bash 3.2.
#
# The server is Onshape's own (Onshape Labs, early access), hosted at URL and
# reached over HTTP. Each person signs in to it with their Onshape account, so
# there is nothing to build and no key to store. Three steps are the person's,
# once, and the script prints them while Claude Code reports the server as not
# signed in:
#   1. Opt into Onshape Labs (Onshape: My account > Preferences).
#   2. Subscribe to "Onshape Labs FeatureScript MCP" in the Onshape App Store (free).
#   3. Sign in: run `claude`, type /mcp, choose onshape, then Authenticate.
#
# Claude Desktop is not changed. Its config file starts local programs only, and
# its Code tab reads Claude Code's settings, so it gets the server from there.
# Desktop's chat would need the URL added as a custom connector in its settings.
#
# `--remove` (run by hand) takes `onshape` out of Claude Code and deletes the
# skill. Sign-out stays with the person (/mcp in Claude Code).

URL="https://fs-mcp.labs.onshape.app/mcp"
NAME="onshape"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$REPO_ROOT/lib/mcp"

# shellcheck source=lib/mcp/common.sh
. "$LIB/common.sh"
if [ -z "$OS" ]; then echo "ℹ️  onshape-mcp: unsupported OS $(uname -s), skipping."; exit 0; fi

# register.mjs runs under Node; Desktop is never written here.
SKIP_DESKTOP=1

if [ "${1:-}" = "--remove" ]; then
    if [ -z "$NODE" ] || [ -z "$CLAUDE" ]; then
        echo "❌ onshape-mcp: Node.js or the claude CLI was not found, so the entry cannot be removed."
        exit 1
    fi
    if ! result="$(mcp_register remove)"; then
        echo "❌ onshape-mcp: could not remove the entry (see the message above)."
        exit 1
    fi
    remove_skill onshape-design
    case "$result" in
        *code=removed*) echo "✅ onshape-mcp: removed \"onshape\" from Claude Code." ;;
        *) echo "✅ onshape-mcp: \"onshape\" was not registered." ;;
    esac
    exit 0
fi

missing=""
[ -n "$NODE" ] || missing="$missing Node.js"
[ -n "$CLAUDE" ] || missing="$missing claude"
if [ -n "$missing" ]; then
    echo "⏭️  onshape-mcp: not found:$missing. Skipping; it will be offered again on the next"
    echo "    bootstrap (a package installed in this run is only visible to a new shell)."
    exit 0
fi

set +e
result="$(MCP_CODE_ENTRY="{\"type\":\"http\",\"url\":\"$URL\"}" mcp_register set)"
status=$?
set -e
if [ "$status" -ne 0 ]; then
    echo "❌ onshape-mcp: registration did not complete (see the message above)."
    exit 1
fi

skill_note="$(remove_skill onshape-design)"

case "$result" in
    *code=added*|*code=replaced*) echo "✅ onshape-mcp: Onshape's FeatureScript MCP server registered as \"onshape\" in Claude Code." ;;
    *) echo "✅ onshape-mcp: Onshape's FeatureScript MCP server already set up; nothing changed." ;;
esac
if [ -n "$skill_note" ]; then echo "$skill_note"; fi

# `claude mcp get` connects to the server to report its status; a signed-in
# server reports "Connected".
if ! "$CLAUDE" mcp get "$NAME" 2>/dev/null | grep -q "Connected"; then
    echo "ℹ️  onshape-mcp: Claude cannot reach your Onshape documents until you do this once:"
    echo "    1. In Onshape, open My account > Preferences and opt into Onshape Labs."
    echo "    2. In the Onshape App Store, subscribe to \"Onshape Labs FeatureScript MCP\" (free)."
    echo "    3. Run claude, type /mcp, choose onshape, then Authenticate, and approve it in"
    echo "       the browser."
fi
