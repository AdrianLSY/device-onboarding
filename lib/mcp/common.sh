# Shared by the MCP tweaks (setup/tweak/kicad-mcp.sh, onshape-mcp.sh, part-db-mcp.sh).
# Sourced, never run: it sets variables and defines functions in the caller.
# Bootstrap CODE, not config. Must stay portable to macOS bash 3.2 and Git Bash.
#
# The caller sets NAME (the server name) and LIB (this directory) first.
# After sourcing, the caller has:
#   OS               macos | windows
#   NODE             absolute path of node, or empty
#   CLAUDE           absolute path of the claude CLI, or empty
#   DESKTOP_CONFIG   Claude Desktop's config file (POSIX path)
#   native <path>    prints the path in the form Node and the apps need
#   mcp_register <set|get|remove>   runs lib/mcp/register.mjs for NAME
#   desktop_ready    0 when Claude Desktop's config may be written (see below)
#   SKIP_DESKTOP     set by desktop_ready's caller; 1 tells register.mjs to leave
#                    Desktop's config alone
#   remove_skill <skill>    deletes the copy an earlier run installed (see below)

case "$(uname -s)" in
    Darwin) OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *) OS="" ;;
esac

native() {
    if [ "$OS" = windows ]; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# Node.js. The opt/ path survives `brew upgrade`, so the absolute path written
# into the app configs stays valid. On Windows a winget install from this same
# bootstrap is not on this session's PATH yet, so its folder is probed directly.
NODE=""
if [ "$OS" = macos ]; then
    for c in /opt/homebrew/opt/node/bin/node /usr/local/opt/node/bin/node; do
        if [ -x "$c" ]; then NODE="$c"; break; fi
    done
elif [ "$OS" = windows ]; then
    c="/c/Program Files/nodejs/node.exe"
    if [ -x "$c" ]; then NODE="$c"; fi
fi
if [ -z "$NODE" ]; then
    NODE="$(command -v node 2>/dev/null || true)"
fi

# The claude CLI (optional: without it only the Claude Code half is skipped).
CLAUDE=""
for c in claude claude.exe "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.exe" /opt/homebrew/bin/claude; do
    if command -v "$c" >/dev/null 2>&1; then CLAUDE="$(command -v "$c")"; break; fi
    if [ -x "$c" ]; then CLAUDE="$c"; break; fi
done

if [ "$OS" = macos ]; then
    DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
elif [ "$OS" = windows ]; then
    # TBD (spike 2.4): confirm this is the file the installed Claude Desktop reads.
    DESKTOP_CONFIG="$(cygpath -u "$APPDATA")/Claude/claude_desktop_config.json"
fi

# A running Claude Desktop keeps its settings in memory and rewrites
# claude_desktop_config.json from that copy, dropping any change made from
# outside (seen 2026-10-07: entries written while it ran were gone within the
# hour). It reads the file only at launch. So the file is written only while
# Desktop is closed.
desktop_running() {
    if [ "$OS" = macos ]; then
        # pgrep -x does not match the app's process name on macOS; match its path.
        # shellcheck disable=SC2009
        ps -axo comm= | grep -qE '/Claude\.app/Contents/MacOS/Claude$'
    else
        # claude.exe is also the Claude Code CLI (~/.local/bin); count only the app.
        # TBD (task 7.2): confirm on Windows.
        local n
        n="$(powershell.exe -NoProfile -NonInteractive -Command \
            "@(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { \$_.Path -and \$_.Path -notmatch '\\\\.local\\\\bin\\\\' }).Count" \
            2>/dev/null | tr -d '\r')"
        [ "${n:-0}" -gt 0 ] 2>/dev/null
    fi
}

# 0 when this script runs inside Claude Desktop: in its terminal panel, or from a
# Claude Code session it started. Quitting Desktop would then kill the script
# before it registers anything (seen 2026-10-08: a pasted token was lost), so
# desktop_ready skips Desktop without asking. macOS walks the parent
# processes; Windows is TBD (task 7.2) and always answers no.
inside_desktop() {
    [ "$OS" = macos ] || return 1
    local pid=$$ comm
    while [ "${pid:-0}" -gt 1 ]; do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || return 1
        case "$comm" in */Claude.app/Contents/*) return 0 ;; esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    done
    return 1
}

# Returns 0 when Desktop is closed, or the person closes it at the prompt;
# 1 when it stays open (no terminal, running inside Desktop, or they chose to
# skip it).
desktop_ready() {
    desktop_running || return 0
    [ -t 0 ] || return 1
    if inside_desktop; then
        echo "ℹ️  This is running inside Claude Desktop, which cannot be quit without stopping it, so"
        echo "    Claude Desktop is skipped."
        return 1
    fi
    echo "⏸️  Claude Desktop is open. While it runs it rewrites its settings file, which would drop"
    echo "    this change."
    while desktop_running; do
        printf '    Quit Claude Desktop (Cmd+Q on a Mac, File > Exit on Windows) and press Enter, or type s to skip it: '
        local answer=""
        IFS= read -r answer </dev/tty || answer=s
        case "$answer" in s|S) return 1 ;; esac
    done
    return 0
}

mcp_register() {
    local claude_native=""
    if [ -n "$CLAUDE" ]; then claude_native="$(native "$CLAUDE")"; fi
    MCP_NAME="$NAME" \
    MCP_DESKTOP_CONFIG="$(native "$DESKTOP_CONFIG")" \
    MCP_CLAUDE_BIN="$claude_native" \
    MCP_SKIP_DESKTOP="${SKIP_DESKTOP:-}" \
        "$NODE" "$(native "$LIB/register.mjs")" "$@"
}

# The kicad-design and onshape-design skills moved to the hardware department's
# skill repo, Rooftop-Energy-Tech/shared-knowledge-hardware-skills, on 2026-10-10.
# A person gets them by mounting that repo in their personal repo, like every other
# department. Earlier runs of these tweaks copied them to ~/.claude/skills/<skill>/
# with a marker file; remove_skill deletes such a copy, so an old version cannot
# shadow the department one. A folder of that name without the marker is someone's
# own skill and is left alone. It prints one line when it removes something.
SKILL_MARK=".installed-by-device-onboarding"
remove_skill() {
    local dst="$HOME/.claude/skills/$1"
    if [ -f "$dst/$SKILL_MARK" ]; then
        rm -rf "$dst"
        echo "    removed the old $1 skill from $dst; it now comes from the hardware-skills repo."
    fi
}
