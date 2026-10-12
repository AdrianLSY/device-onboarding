#!/bin/bash
set -e

# part-db-mcp tweak: gives Claude Code and Claude Desktop access to Rooftop's
# Part-DB (component inventory) through Part-DB's own MCP endpoint, registered
# as `part-db` in both apps. Claude can look up parts and stock, and add the
# parts a KiCad design uses (the kicad-design skill, in the hardware-skills repo).
#
# SHARED ACROSS TIERS: canonical script; windows/setup/tweak/part-db-mcp.sh is a
# two-line exec wrapper. Portable to macOS bash 3.2 and Git Bash. No `set -x`:
# the token must never reach the runner's log.
#
# Each person uses their own Part-DB API token with the Edit scope:
# Part-DB -> your user settings -> API -> create token. The tweak:
#   1. Re-checks a token already registered; a working Edit token means no
#      prompt. A Read-Only one (the scope used until 2026-10-08) still works for
#      lookups, so it is kept unless the person gives an Edit token to replace it.
#   2. Otherwise asks for one, on a terminal only (no terminal: changes nothing,
#      exit 0). Enter skips, or keeps the Read-Only token, and the next
#      bootstrap asks again.
#   3. Checks the token with Part-DB (lib/mcp/check.mjs token). A rejected token,
#      a Read-Only one, or an Admin or Full one is refused. If Part-DB cannot be
#      reached (the tailnet is joined later in the same bootstrap), the token is
#      saved with a warning and checked again on the next run.
#   4. Registers `part-db` in Claude Code (direct HTTP) and in Claude Desktop,
#      which can only start local programs, through a pinned mcp-remote installed
#      from lib/mcp/bridge/. The token goes into Desktop's config as an env value
#      that mcp-remote expands itself, so it stays out of process arguments.
#   5. If Part-DB answers, runs an MCP handshake and requires `create_part`
#      (`search_parts` for a kept Read-Only token). Part-DB lists a tool only if
#      the person's group may use it, so this also proves they can add parts.
#
# The token is kept only in the two app configs (both mode 600 on macOS).
# Changing it: create a new token, delete the old one in Part-DB, re-run.
# `--remove` (run by hand) takes `part-db` out of both apps and deletes the
# bridge. For a leaver, deleting their token in Part-DB is the real control.

NAME="part-db"
# Part-DB runs on both office boxes against one database, active/passive.
# Clients use the Dyna box while the Rooftop office is on 5G (from 2026-10-08:
# its database round trips took 4 to 40 seconds and Part-DB stopped answering).
# Switch back to http://ubuntu-rooftop.ts.rooftop.my:8095/ when the Rooftop
# fibre returns, then re-run this tweak on each machine: a changed URL replaces
# the registered entry and keeps the token, which works on either box.
BASE="http://ubuntu-dyna.ts.rooftop.my:8095/"
URL="${BASE}mcp"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$REPO_ROOT/lib/mcp"
BRIDGE_DIR="$HOME/.local/share/rooftop-mcp/mcp-remote"

# shellcheck source=lib/mcp/common.sh
. "$LIB/common.sh"
if [ -z "$OS" ]; then echo "ℹ️  part-db-mcp: unsupported OS $(uname -s), skipping."; exit 0; fi

if [ -z "$NODE" ]; then
    echo "⏭️  part-db-mcp: Node.js not found. Skipping; it will be offered again on the next"
    echo "    bootstrap (a package installed by winget in this run is only visible to a new shell)."
    exit 0
fi
NODE_DIR="$(dirname "$NODE")"
export PATH="$NODE_DIR:$PATH"

# --- --remove --------------------------------------------------------------------
if [ "${1:-}" = "--remove" ]; then
    SKIP_DESKTOP=""
    desktop_ready || SKIP_DESKTOP=1
    if ! result="$(mcp_register remove)"; then
        echo "❌ part-db-mcp: could not remove the entries (see the message above)."
        exit 1
    fi
    printf '%s\n' "$result" | sed -n 's/^backup=/    backed up Claude Desktop config to /p'
    rm -rf "$BRIDGE_DIR"
    case "$result" in *desktop=skipped*)
        echo "ℹ️  part-db-mcp: Claude Desktop was left open, so its entry stays until you run this again with it closed." ;;
    esac
    where=""
    case "$result" in *code=removed*) where="Claude Code" ;; esac
    case "$result" in *desktop=removed*) where="${where:+$where and }Claude Desktop" ;; esac
    case "$result" in
        *desktop=removed*|*code=removed*)
            echo "✅ part-db-mcp: removed \"part-db\" from $where."
            echo "    Delete the token in Part-DB too." ;;
        *)
            echo "✅ part-db-mcp: nothing was registered." ;;
    esac
    exit 0
fi

check_token() { # $1 = token; prints check.mjs's message; returns its exit code
    PARTDB_BASE="$BASE" MCP_TOKEN="$1" "$NODE" "$(native "$LIB/check.mjs")" token
}

# --- 1. A token already registered? --------------------------------------------------
existing="$(mcp_register get 2>/dev/null | "$NODE" -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
        try {
            const j = JSON.parse(s);
            const h = j.code?.headers?.Authorization ?? j.desktop?.env?.AUTH_HEADER ?? "";
            process.stdout.write(h.replace(/^Bearer\s+/i, ""));
        } catch { /* nothing registered */ }
    });' || true)"

TOKEN=""
READONLY="" # a registered Read-Only token, kept when no Edit token is given
if [ -n "$existing" ]; then
    set +e
    msg="$(check_token "$existing")"; rc=$?
    set -e
    case "$rc" in
        0) TOKEN="$existing" ;;
        3) TOKEN="$existing"
           echo "ℹ️  part-db-mcp: $msg Keeping the registered token; it is checked again next run." ;;
        6) READONLY="$existing" ;;
        *) echo "⚠️  part-db-mcp: the registered token no longer works: $msg" ;;
    esac
fi

keep_readonly() {
    TOKEN="$READONLY"
    echo "ℹ️  part-db-mcp: keeping your Read-Only token, so Claude can look up parts but not add"
    echo "    them. Run this again with an Edit token when you want it to add parts."
}

# --- 2. Ask for one -----------------------------------------------------------------
if [ -z "$TOKEN" ]; then
    if [ ! -t 0 ]; then
        if [ -n "$READONLY" ]; then
            echo "ℹ️  part-db-mcp: your Part-DB token is Read-Only, so Claude can look up parts but not add"
            echo "    them. Run this in a terminal with an Edit token to let it add parts."
        else
            echo "⏭️  part-db-mcp: no interactive terminal. Part-DB access for Claude will be offered on"
            echo "    the next interactive bootstrap."
        fi
        exit 0
    fi
    if [ -n "$READONLY" ]; then
        echo "🔑 part-db-mcp: your Part-DB token is Read-Only. Claude can now add the parts a KiCad design"
        echo "    uses, which needs a token with the Edit scope. In Part-DB (${BASE}en/), open your"
        echo "    user settings, then API, and create one. Paste it below (it will not be shown), or"
        echo "    press Enter to keep the Read-Only token."
    else
        echo "🔑 part-db-mcp: Claude can look up parts and stock in Part-DB, and add the parts a KiCad"
        echo "    design uses, with your own Part-DB token. In Part-DB (${BASE}en/), open your user"
        echo "    settings, then API, and create a token with the Edit scope. Paste it below (it will"
        echo "    not be shown), or press Enter to skip."
    fi
    attempt=0
    while [ -z "$TOKEN" ] && [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        printf '    Part-DB token: '
        IFS= read -r -s candidate </dev/tty || candidate=""
        echo
        candidate="$(printf '%s' "$candidate" | tr -d '[:space:]')"
        if [ -z "$candidate" ]; then
            if [ -n "$READONLY" ]; then keep_readonly; break; fi
            echo "⏭️  part-db-mcp: skipped. The next bootstrap will ask again."
            exit 0
        fi
        case "$candidate" in
            tcp_*) ;;
            *) echo "    That does not look like a Part-DB API token (they start with tcp_)."; continue ;;
        esac
        set +e
        msg="$(check_token "$candidate")"; rc=$?
        set -e
        case "$rc" in
            0) TOKEN="$candidate"; echo "    $msg" ;;
            3) TOKEN="$candidate"
               echo "⚠️  part-db-mcp: $msg Saving the token unchecked; it is checked on the next run"
               echo "    (Part-DB is reachable only over the tailnet)." ;;
            6) echo "    $msg Create one with the Edit scope." ;;
            *) echo "    $msg" ;;
        esac
    done
    if [ -z "$TOKEN" ] && [ -n "$READONLY" ]; then keep_readonly; fi
    if [ -z "$TOKEN" ]; then
        echo "⏭️  part-db-mcp: no working Edit token after three tries. Skipping; the next"
        echo "    bootstrap will ask again."
        exit 0
    fi
fi

# --- 3. Bridge for Claude Desktop ------------------------------------------------------
PROXY="$BRIDGE_DIR/node_modules/mcp-remote/dist/proxy.js"
if [ ! -f "$PROXY" ] || ! cmp -s "$LIB/bridge/package-lock.json" "$BRIDGE_DIR/package-lock.json"; then
    rm -rf "$BRIDGE_DIR"
    mkdir -p "$BRIDGE_DIR"
    cp "$LIB/bridge/package.json" "$LIB/bridge/package-lock.json" "$BRIDGE_DIR/"
    # --ignore-scripts: nothing in mcp-remote's tree needs an install script.
    if ! ( cd "$BRIDGE_DIR" && "$NODE_DIR/npm" ci --ignore-scripts --no-audit --no-fund --loglevel=error >/dev/null ); then
        echo "❌ part-db-mcp: installing mcp-remote for Claude Desktop failed."
        rm -rf "$BRIDGE_DIR"
        exit 1
    fi
fi

# --- 4. Register ---------------------------------------------------------------------
# ${AUTH_HEADER} is literal on purpose: mcp-remote expands it from the entry's env.
# shellcheck disable=SC2016
entry_json() { # $1 = desktop | code; the token arrives in E_TOKEN
    KIND="$1" E_TOKEN="$TOKEN" E_URL="$URL" E_NODE="$(native "$NODE")" E_PROXY="$(native "$PROXY")" \
        "$NODE" -e '
        const e = process.env;
        const out = e.KIND === "code"
            ? { type: "http", url: e.E_URL, headers: { Authorization: "Bearer " + e.E_TOKEN } }
            : { command: e.E_NODE,
                args: [e.E_PROXY, e.E_URL, "--allow-http", "--header", "Authorization:${AUTH_HEADER}"],
                env: { AUTH_HEADER: "Bearer " + e.E_TOKEN } };
        process.stdout.write(JSON.stringify(out));'
}

SKIP_DESKTOP=""
desktop_ready || SKIP_DESKTOP=1
set +e
result="$(MCP_DESKTOP_ENTRY="$(entry_json desktop)" MCP_CODE_ENTRY="$(entry_json code)" mcp_register set)"
status=$?
set -e
printf '%s\n' "$result" | sed -n 's/^backup=/    backed up Claude Desktop config to /p'
if [ "$status" -ne 0 ]; then
    echo "❌ part-db-mcp: registration did not complete (see the message above)."
    exit 1
fi

# --- 5. Handshake ----------------------------------------------------------------------
REQUIRE=create_part
if [ "$TOKEN" = "$READONLY" ]; then REQUIRE=search_parts; fi
set +e
msg="$(MCP_URL="$URL" MCP_TOKEN="$TOKEN" MCP_REQUIRE_TOOL="$REQUIRE" "$NODE" "$(native "$LIB/check.mjs")" http)"; rc=$?
set -e
case "$rc" in
    0) echo "    $msg" ;;
    3) echo "ℹ️  part-db-mcp: Part-DB is not reachable from here right now (tailnet off?). The"
       echo "    entries are in place and work once the laptop is on the tailnet." ;;
    *) echo "❌ part-db-mcp: $msg"
       if [ "$REQUIRE" = create_part ]; then
           echo "    Part-DB lists a tool only if your group may use it, so ask a Part-DB admin to let"
           echo "    your group create and edit parts, then run this again."
       fi
       exit 1 ;;
esac
if [ -n "$READONLY" ] && [ "$TOKEN" != "$READONLY" ]; then
    echo "    Your old Read-Only token is now unused: delete it in Part-DB (user settings, API)."
fi

case "$result" in *desktop=skipped*)
    echo "ℹ️  part-db-mcp: Claude Desktop was left open, so it was not changed. Run this again with"
    echo "    Claude Desktop closed, or let the next bootstrap do it." ;;
esac
case "$result" in *code=skipped*)
    echo "ℹ️  part-db-mcp: the claude CLI was not found, so Claude Code was skipped; it will be"
    echo "    registered on the next bootstrap." ;;
esac
case "$result" in *desktop=added*|*desktop=replaced*)
    echo "✅ part-db-mcp: Part-DB registered as \"part-db\"."
    echo "    Open Claude Desktop to load it (it reads its settings only at launch)." ;;
*)
    case "$result" in *code=added*|*code=replaced*)
        echo "✅ part-db-mcp: Part-DB registered as \"part-db\" in Claude Code." ;;
    *desktop=skipped*)
        echo "✅ part-db-mcp: Part-DB is set up in Claude Code; Claude Desktop is still to do (above)." ;;
    *)
        echo "✅ part-db-mcp: Part-DB already set up; nothing changed." ;;
    esac ;;
esac
