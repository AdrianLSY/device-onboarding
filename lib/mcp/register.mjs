// Registers one MCP server in both Claude apps: Claude Code (user scope) and
// Claude Desktop (claude_desktop_config.json). Used by kicad-mcp.sh,
// part-db-mcp.sh and, for Claude Code only, onshape-mcp.sh.
//
// Bootstrap CODE, not config: run by the tweaks with the absolute `node` they
// resolved. Node built-ins only.
//
//   node register.mjs set      write the entry where it differs
//   node register.mjs get      print {"code": <entry|null>, "desktop": <entry|null>}
//   node register.mjs remove   take the entry out of both apps
//
// Inputs, all in the ENVIRONMENT (entries may hold a token, so never argv):
//   MCP_NAME             server name, e.g. kicad
//   MCP_DESKTOP_CONFIG   absolute path of claude_desktop_config.json
//   MCP_DESKTOP_ENTRY    JSON entry for Claude Desktop            (set; optional
//                        with MCP_SKIP_DESKTOP=1)
//   MCP_CODE_ENTRY       JSON entry for Claude Code               (set; optional)
//   MCP_CLAUDE_BIN       absolute path of the claude CLI; empty = skip Claude Code
//   MCP_SKIP_DESKTOP     1 = leave Claude Desktop's config alone (it is running and
//                        would overwrite the file from memory; see common.sh)
//
// `set` prints machine-readable lines the tweak reads:
//   desktop=added|replaced|unchanged|skipped   code=added|replaced|unchanged|skipped
//   backup=<path>                      (when the Desktop config was backed up)
//
// Claude Desktop: only this entry changes; every other key and server is kept.
// The file is backed up to <file>.bak.<timestamp> before its first change,
// written to a temp file in the same directory and renamed into place, mode
// 600. A file that is not valid JSON, or whose top level or mcpServers is not
// an object, is left untouched and the run exits 2.
//
// Claude Code: ~/.claude.json belongs to the claude CLI and is rewritten by
// running sessions, so it is only READ here, to compare. Changes go through
// `claude mcp remove` / `claude mcp add-json --scope user`. add-json takes the
// entry as an argument, so a token is in that one command's argv while it
// runs; that is the accepted cost of not editing the file under Claude Code.
//
// Exit codes: 0 ok, 1 failed, 2 Desktop config unreadable (left alone), 64 usage.

import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync, chmodSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

const action = process.argv[2];
const name = process.env.MCP_NAME;
const desktopPath = process.env.MCP_DESKTOP_CONFIG;
const claudeBin = process.env.MCP_CLAUDE_BIN || "";
const skipDesktop = process.env.MCP_SKIP_DESKTOP === "1";

function die(code, message) {
    process.stderr.write(`register.mjs: ${message}\n`);
    process.exit(code);
}

if (!["set", "get", "remove"].includes(action)) die(64, "usage: node register.mjs set|get|remove (inputs in the environment)");
if (!name || !desktopPath) die(64, "MCP_NAME and MCP_DESKTOP_CONFIG are required.");

function parseEntry(variable) {
    const raw = process.env[variable];
    if (!raw) return null;
    try {
        const value = JSON.parse(raw);
        if (value && typeof value === "object" && !Array.isArray(value)) return value;
    } catch {
        // fall through
    }
    die(64, `${variable} is not a JSON object.`);
}

// Key-order-independent comparison.
function canonical(value) {
    if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
    if (value && typeof value === "object") {
        return `{${Object.keys(value)
            .sort()
            .map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`)
            .join(",")}}`;
    }
    return JSON.stringify(value);
}
const same = (a, b) => canonical(a) === canonical(b);

// --- Claude Desktop -----------------------------------------------------------

// Returns { data } for a usable file (data = {} when absent), or exits 2.
function readDesktop() {
    if (!existsSync(desktopPath)) return { data: {}, existed: false };
    let data;
    try {
        data = JSON.parse(readFileSync(desktopPath, "utf8"));
    } catch {
        data = undefined;
    }
    const usable =
        data &&
        typeof data === "object" &&
        !Array.isArray(data) &&
        (data.mcpServers === undefined || (data.mcpServers && typeof data.mcpServers === "object" && !Array.isArray(data.mcpServers)));
    if (!usable) return { unreadable: true };
    return { data, existed: true };
}

function timestamp() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function backupDesktop() {
    let target = `${desktopPath}.bak.${timestamp()}`;
    for (let n = 1; existsSync(target); n++) target = `${desktopPath}.bak.${timestamp()}.${n}`;
    copyFileSync(desktopPath, target);
    if (process.platform !== "win32") chmodSync(target, 0o600);
    return target;
}

function writeDesktop(data) {
    mkdirSync(dirname(desktopPath), { recursive: true });
    const tmp = join(dirname(desktopPath), `.${basename(desktopPath)}.tmp-${process.pid}`);
    try {
        writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
        renameSync(tmp, desktopPath);
    } finally {
        if (existsSync(tmp)) unlinkSync(tmp);
    }
    if (process.platform !== "win32") chmodSync(desktopPath, 0o600);
}

// --- Claude Code --------------------------------------------------------------

function claudeConfigPath() {
    const dir = process.env.CLAUDE_CONFIG_DIR;
    return dir ? join(dir, ".claude.json") : join(homedir(), ".claude.json");
}

function readCodeEntry() {
    const path = claudeConfigPath();
    if (!existsSync(path)) return null;
    // A running Claude Code session may be mid-write; retry once.
    for (let attempt = 0; attempt < 2; attempt++) {
        try {
            const data = JSON.parse(readFileSync(path, "utf8"));
            return data?.mcpServers?.[name] ?? null;
        } catch {
            if (attempt === 0) execFileSync(process.execPath, ["-e", "setTimeout(()=>{},500)"]);
        }
    }
    die(1, `${path} could not be read.`);
}

function claude(args) {
    const shell = /\.(cmd|bat)$/i.test(claudeBin);
    execFileSync(claudeBin, args, { stdio: ["ignore", "ignore", "pipe"], shell, windowsHide: true });
}

// --- actions ------------------------------------------------------------------

if (action === "get") {
    const desktop = readDesktop();
    const out = {
        code: claudeBin || existsSync(claudeConfigPath()) ? readCodeEntry() : null,
        desktop: desktop.unreadable ? null : (desktop.data.mcpServers?.[name] ?? null),
    };
    process.stdout.write(`${JSON.stringify(out)}\n`);
    process.exit(0);
}

if (action === "remove") {
    const desktop = skipDesktop ? { data: {} } : readDesktop();
    if (desktop.unreadable) die(2, `${desktopPath} is not valid JSON; left alone.`);
    if (skipDesktop) {
        process.stdout.write("desktop=skipped\n");
    } else if (desktop.data.mcpServers?.[name] !== undefined) {
        process.stdout.write(`backup=${backupDesktop()}\n`);
        delete desktop.data.mcpServers[name];
        writeDesktop(desktop.data);
        process.stdout.write("desktop=removed\n");
    } else {
        process.stdout.write("desktop=absent\n");
    }
    if (!claudeBin) {
        process.stdout.write("code=skipped\n");
    } else if (readCodeEntry() !== null) {
        claude(["mcp", "remove", "--scope", "user", name]);
        process.stdout.write("code=removed\n");
    } else {
        process.stdout.write("code=absent\n");
    }
    process.exit(0);
}

// set
const desktopEntry = parseEntry("MCP_DESKTOP_ENTRY");
const codeEntry = parseEntry("MCP_CODE_ENTRY");
if (!desktopEntry && !skipDesktop) die(64, "MCP_DESKTOP_ENTRY is required for set, unless MCP_SKIP_DESKTOP=1.");

let exitCode = 0;
const desktop = skipDesktop ? null : readDesktop();
if (skipDesktop) {
    process.stdout.write("desktop=skipped\n");
} else if (desktop.unreadable) {
    process.stderr.write(`register.mjs: ${desktopPath} is not valid JSON (or its mcpServers is not an object); left alone. Fix or move it aside, then re-run.\n`);
    exitCode = 2;
} else {
    const current = desktop.data.mcpServers?.[name];
    if (current !== undefined && same(current, desktopEntry)) {
        process.stdout.write("desktop=unchanged\n");
    } else {
        if (desktop.existed) process.stdout.write(`backup=${backupDesktop()}\n`);
        if (!desktop.data.mcpServers) desktop.data.mcpServers = {};
        desktop.data.mcpServers[name] = desktopEntry;
        writeDesktop(desktop.data);
        process.stdout.write(`desktop=${current === undefined ? "added" : "replaced"}\n`);
    }
}

if (!claudeBin || !codeEntry) {
    process.stdout.write("code=skipped\n");
} else {
    const current = readCodeEntry();
    if (current !== null && same(current, codeEntry)) {
        process.stdout.write("code=unchanged\n");
    } else {
        try {
            if (current !== null) claude(["mcp", "remove", "--scope", "user", name]);
            claude(["mcp", "add-json", "--scope", "user", name, JSON.stringify(codeEntry)]);
        } catch (err) {
            // stderr from claude never holds the entry, but trim it anyway.
            die(1, `claude mcp failed: ${String(err.stderr ?? err.message).trim().slice(0, 300)}`);
        }
        const after = readCodeEntry();
        if (!after || !same(after, codeEntry)) die(1, "Claude Code did not record the entry as written.");
        process.stdout.write(`code=${current === null ? "added" : "replaced"}\n`);
    }
}
process.exit(exitCode);
