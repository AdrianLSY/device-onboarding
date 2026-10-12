#!/bin/bash
set -e

# kicad-mcp tweak: installs the KiCad MCP server and registers it as `kicad` in
# Claude Code (user scope) and Claude Desktop, so either app can read and work on
# KiCad schematics and boards.
#
# SHARED ACROSS TIERS: this file is the canonical script. The Windows tier runs it
# through windows/setup/tweak/kicad-mcp.sh, a two-line exec wrapper (a symlink
# would not survive the USB copy that provisions Windows), so it must stay
# portable to Git Bash/MSYS and to macOS's bash 3.2.
#
# What it does, in order:
#   1. Finds KiCad's bundled Python, Node.js, git and the claude CLI. Missing
#      KiCad, Node or git skips the tweak (exit 0) and it is offered again next
#      bootstrap; a missing claude only skips the Claude Code half.
#   2. Builds mixelpixx/KiCAD-MCP-Server at the pinned TAG into
#      ~/.local/share/rooftop-mcp/kicad-mcp-server/<tag>-py<X.Y>-node<N>/, after
#      checking the tag still resolves to COMMIT. The venv is made from KiCad's
#      own interpreter with --system-site-packages, so pcbnew imports. The key
#      changes when KiCad's Python or Node's major version does, so the next
#      bootstrap rebuilds instead of running a stale venv or node_modules.
#   3. Starts the new build and checks it answers (lib/mcp/check.mjs), including
#      a tool call that needs pcbnew. Only then is it registered, and the
#      `current` file rewritten last. A failed build leaves the previous one
#      registered and exits 1, so the runner lists the tweak as failed.
#   4. Registers it in both apps (lib/mcp/register.mjs): only the `kicad` entry
#      changes, Claude Desktop's config is backed up first, and a malformed
#      config is left alone.
#   5. Removes the kicad-design skill an earlier run copied into ~/.claude/skills/
#      (it has a marker file). The skill now lives in the hardware-skills
#      department repo, mounted in a personal repo like every other department.
#
# `--remove` (run by hand) takes `kicad` out of both apps and deletes the install
# directory and the skill. Everything under ~/.local/share/rooftop-mcp is
# reproducible.
#
# Pin bump: change TAG and COMMIT (the commit the tag points at, NOT the tag
# object: `git ls-remote <url> 'refs/tags/<tag>^{}'`), regenerate
# lib/mcp/kicad-constraints-*.txt, and review upstream's diff. See CLAUDE.md.

TAG="v2.8.2"
COMMIT="670d2a9c48e1588f2e07edaf656b5e301fc55a50"
REPO_URL="https://github.com/mixelpixx/KiCAD-MCP-Server.git"
NAME="kicad"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$REPO_ROOT/lib/mcp"
INSTALL_ROOT="$HOME/.local/share/rooftop-mcp/kicad-mcp-server"

# shellcheck source=lib/mcp/common.sh
. "$LIB/common.sh"
if [ -z "$OS" ]; then echo "ℹ️  kicad-mcp: unsupported OS $(uname -s), skipping."; exit 0; fi

# --- --remove --------------------------------------------------------------------
if [ "${1:-}" = "--remove" ]; then
    if [ -z "$NODE" ]; then
        echo "❌ kicad-mcp: Node.js not found, so the Claude app entries cannot be removed."
        exit 1
    fi
    SKIP_DESKTOP=""
    desktop_ready || SKIP_DESKTOP=1
    if ! result="$(mcp_register remove)"; then
        echo "❌ kicad-mcp: could not remove the entries (see the message above)."
        exit 1
    fi
    printf '%s\n' "$result" | sed -n 's/^backup=/    backed up Claude Desktop config to /p'
    rm -rf "$INSTALL_ROOT"
    remove_skill kicad-design
    case "$result" in *desktop=skipped*)
        echo "ℹ️  kicad-mcp: Claude Desktop was left open, so its entry stays until you run this again with it closed." ;;
    esac
    where=""
    case "$result" in *code=removed*) where="Claude Code" ;; esac
    case "$result" in *desktop=removed*) where="${where:+$where and }Claude Desktop" ;; esac
    case "$result" in
        *desktop=removed*|*code=removed*)
            echo "✅ kicad-mcp: removed \"kicad\" from $where and deleted"
            echo "    $INSTALL_ROOT." ;;
        *)
            echo "✅ kicad-mcp: nothing was registered; $INSTALL_ROOT is gone." ;;
    esac
    exit 0
fi

# --- Prerequisites -----------------------------------------------------------------
KPY=""
if [ "$OS" = macos ]; then
    c="/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3"
    if [ -x "$c" ]; then KPY="$c"; fi
else
    # Machine-wide and per-user installs; the highest version wins.
    while IFS= read -r c; do
        if [ -n "$c" ] && [ -x "$c" ]; then KPY="$c"; fi
    done <<EOF
$(# shellcheck disable=SC2012  # paths are fixed install folders; ls -d keeps sort -V simple
  ls -d "/c/Program Files/KiCad"/*/bin/python.exe \
        "$(cygpath -u "${LOCALAPPDATA:-C:\\}")/Programs/KiCad"/*/bin/python.exe 2>/dev/null | sort -V)
EOF
fi

missing=""
[ -n "$KPY" ] || missing="$missing KiCad"
[ -n "$NODE" ] || missing="$missing Node.js"
command -v git >/dev/null 2>&1 || missing="$missing git"
if [ -n "$missing" ]; then
    echo "⏭️  kicad-mcp: not found:$missing. Skipping; it will be offered again on the next"
    echo "    bootstrap (a package installed by winget in this run is only visible to a new shell)."
    exit 0
fi

NODE_DIR="$(dirname "$NODE")"
export PATH="$NODE_DIR:$PATH"
NPM="$NODE_DIR/npm"
PYVER="$("$KPY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' | tr -d '\r')"
NODE_MAJOR="$("$NODE" -p 'process.versions.node.split(".")[0]' | tr -d '\r')"
KEY="${TAG}-py${PYVER}-node${NODE_MAJOR}"
BUILD="$INSTALL_ROOT/$KEY"
if [ "$OS" = windows ]; then VPY="$BUILD/venv/Scripts/python.exe"; else VPY="$BUILD/venv/bin/python"; fi
INDEX="$BUILD/dist/index.js"

# The server prefers an in-tree venv/ and falls back to KICAD_PYTHON; a second
# code path reads only KICAD_PYTHON, so it is set too.
build_env_json() {
    E_PY="$(native "$VPY")" "$NODE" -e 'process.stdout.write(JSON.stringify({
        KICAD_PYTHON: process.env.E_PY, KICAD_AUTO_LAUNCH: "false",
        LOG_LEVEL: "info", NODE_ENV: "production" }))'
}

# --- Build (only when this key has no complete build) ------------------------------
if [ ! -f "$BUILD/.complete" ]; then
    echo "🔧 kicad-mcp: building KiCad MCP server $TAG (Python $PYVER, Node $NODE_MAJOR)."
    mkdir -p "$INSTALL_ROOT"
    rm -rf "$BUILD"

    # A shallow clone of an annotated tag warns "<tag object> is not a commit!";
    # that line is expected and filtered, anything else is shown.
    set +e
    out="$(git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$REPO_URL" "$BUILD" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out" | grep -v 'is not a commit!' | grep -v '^$' || true
    if [ "$rc" -ne 0 ]; then
        echo "❌ kicad-mcp: could not download $TAG from $REPO_URL."
        rm -rf "$BUILD"; exit 1
    fi
    head="$(git -C "$BUILD" rev-parse HEAD)"
    if [ "$head" != "$COMMIT" ]; then
        echo "❌ kicad-mcp: tag $TAG now points at $head, not the reviewed $COMMIT."
        echo "    Upstream moved the tag. Nothing was installed; review before changing the pin."
        rm -rf "$BUILD"; exit 1
    fi

    constraints=""
    if [ -f "$LIB/kicad-constraints-$OS.txt" ]; then constraints="$LIB/kicad-constraints-$OS.txt"; fi
    if ! "$KPY" -m venv --system-site-packages "$BUILD/venv" \
        || ! "$VPY" -m pip install --quiet --disable-pip-version-check \
               -r "$(native "$BUILD/requirements.txt")" \
               ${constraints:+-c "$(native "$constraints")"}; then
        echo "❌ kicad-mcp: installing the Python dependencies failed."
        exit 1
    fi
    # --ignore-scripts: no third-party install script runs; the build is explicit.
    if ! ( cd "$BUILD" && "$NPM" ci --ignore-scripts --no-audit --no-fund --loglevel=error \
           && "$NPM" run build --silent ); then
        echo "❌ kicad-mcp: building the server failed."
        exit 1
    fi

    echo "🔍 kicad-mcp: checking the new build starts and can load KiCad's pcbnew."
    if ! MCP_COMMAND="$(E_NODE="$(native "$NODE")" E_INDEX="$(native "$INDEX")" "$NODE" -e \
            'process.stdout.write(JSON.stringify([process.env.E_NODE, process.env.E_INDEX]))')" \
         MCP_ENV="$(build_env_json)" \
         MCP_PROBE_TOOL=get_backend_state MCP_PROBE_RETRY_PATTERN="not running" \
         "$NODE" "$(native "$LIB/check.mjs")" stdio; then
        echo "❌ kicad-mcp: the new build did not pass its check. The previous build, if any,"
        echo "    stays registered."
        exit 1
    fi
    touch "$BUILD/.complete"
fi

# --- Register ----------------------------------------------------------------------
entry_json() { # $1 = desktop | code
    KIND="$1" E_NODE="$(native "$NODE")" E_INDEX="$(native "$INDEX")" E_ENV="$(build_env_json)" \
        "$NODE" -e 'const e = { command: process.env.E_NODE, args: [process.env.E_INDEX],
                               env: JSON.parse(process.env.E_ENV) };
                    process.stdout.write(JSON.stringify(process.env.KIND === "code" ? { type: "stdio", ...e } : e));'
}

SKIP_DESKTOP=""
desktop_ready || SKIP_DESKTOP=1
set +e
result="$(MCP_DESKTOP_ENTRY="$(entry_json desktop)" MCP_CODE_ENTRY="$(entry_json code)" mcp_register set)"
status=$?
set -e
printf '%s\n' "$result" | sed -n 's/^backup=/    backed up Claude Desktop config to /p'
if [ "$status" -ne 0 ]; then
    echo "❌ kicad-mcp: registration did not complete (see the message above)."
    exit 1
fi

# --- Skill ---------------------------------------------------------------------------
skill_note="$(remove_skill kicad-design)"

prev="$(cat "$INSTALL_ROOT/current" 2>/dev/null | tr -d '\r\n' || true)"
printf '%s\n' "$KEY" > "$INSTALL_ROOT/current"
for d in "$INSTALL_ROOT"/v*; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    if [ "$b" != "$KEY" ] && [ "$b" != "$prev" ]; then rm -rf "$d"; fi
done

case "$result" in *desktop=skipped*)
    echo "ℹ️  kicad-mcp: Claude Desktop was left open, so it was not changed. Run this again with"
    echo "    Claude Desktop closed, or let the next bootstrap do it." ;;
esac
case "$result" in *code=skipped*)
    echo "ℹ️  kicad-mcp: the claude CLI was not found, so Claude Code was skipped; it will be"
    echo "    registered on the next bootstrap." ;;
esac
case "$result" in *desktop=added*|*desktop=replaced*)
    echo "✅ kicad-mcp: KiCad MCP server $TAG registered as \"kicad\"."
    echo "    Open Claude Desktop to load it (it reads its settings only at launch)." ;;
*)
    case "$result" in *code=added*|*code=replaced*)
        echo "✅ kicad-mcp: KiCad MCP server $TAG registered as \"kicad\" in Claude Code." ;;
    *desktop=skipped*)
        echo "✅ kicad-mcp: KiCad MCP server $TAG is set up in Claude Code; Claude Desktop is still to do (above)." ;;
    *)
        echo "✅ kicad-mcp: KiCad MCP server $TAG already set up; nothing changed." ;;
    esac ;;
esac
if [ -n "$skill_note" ]; then echo "$skill_note"; fi
