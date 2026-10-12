// Outcome checks for the MCP tweaks (kicad-mcp.sh, part-db-mcp.sh).
//
// Bootstrap CODE, not config: run by the tweaks with the absolute `node` they
// resolved, never deployed. Node built-ins only, so it works before any npm
// install and on a bare Windows box.
//
//   node check.mjs stdio   MCP_COMMAND='["/abs/node","/abs/dist/index.js"]'
//                          [MCP_ENV='{"KEY":"value"}'] [MCP_TIMEOUT_MS=60000]
//                          [MCP_PROBE_TOOL=get_backend_state]
//                          [MCP_PROBE_RETRY_PATTERN='not running']
//       Starts a local server, runs initialize + tools/list over stdio, and
//       passes when the server lists at least one tool. With MCP_PROBE_TOOL it
//       then calls that tool (no arguments), retrying once a second while the
//       answer matches MCP_PROBE_RETRY_PATTERN, and passes only on a non-error
//       answer. The KiCad server needs this: its Python side starts a few
//       seconds after the Node side, and only a tool call proves pcbnew loads.
//
//   node check.mjs http    MCP_URL=http://host/mcp  MCP_TOKEN=tcp_...
//                          [MCP_REQUIRE_TOOL=search_parts] [MCP_TIMEOUT_MS=15000]
//       The same handshake over Streamable HTTP with a bearer token.
//
//   node check.mjs token   PARTDB_BASE=http://host:8095/  MCP_TOKEN=tcp_...
//                          [MCP_TIMEOUT_MS=10000]
//       Asks Part-DB which token this is (GET /api/tokens/current). Passes for
//       an Edit token; a Read-Only one gets its own exit code (it still works
//       for lookups); Admin and Full are refused as wider than Claude needs.
//
// Secrets arrive in the ENVIRONMENT, never in argv, and are never printed.
//
// Exit codes (the tweaks branch on them):
//   0 passed   1 failed   2 usage   3 unreachable   4 token rejected   5 wrong scope
//   6 read-only token (token mode only)

import { spawn } from "node:child_process";

const PROTOCOL = "2025-06-18";
const CLIENT = { name: "device-onboarding-check", version: "1" };

const EXIT = { ok: 0, failed: 1, usage: 2, unreachable: 3, rejected: 4, scope: 5, readOnly: 6 };

function done(code, message) {
    process.stdout.write(`${message}\n`);
    process.exit(code);
}

function envJson(name, fallback) {
    const raw = process.env[name];
    if (!raw) return fallback;
    try {
        return JSON.parse(raw);
    } catch {
        done(EXIT.usage, `check.mjs: ${name} is not valid JSON.`);
    }
}

function timeoutMs(fallback) {
    const n = Number(process.env.MCP_TIMEOUT_MS);
    return Number.isFinite(n) && n > 0 ? n : fallback;
}

// --- stdio --------------------------------------------------------------------

async function checkStdio() {
    const command = envJson("MCP_COMMAND", null);
    if (!Array.isArray(command) || command.length === 0) {
        done(EXIT.usage, "check.mjs: MCP_COMMAND must be a JSON array [program, ...args].");
    }
    const extraEnv = envJson("MCP_ENV", {});
    const limit = timeoutMs(60000);

    // Own process group off Windows, so stopping the server also stops the
    // Python children it spawned; killing only Node left them running.
    const group = process.platform !== "win32";
    const child = spawn(command[0], command.slice(1), {
        env: { ...process.env, ...extraEnv },
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
        detached: group,
    });
    const stop = () => {
        try {
            if (group) process.kill(-child.pid, "SIGTERM");
            else spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
        } catch {
            child.kill();
        }
    };

    let stderrTail = "";
    child.stderr.on("data", (chunk) => {
        stderrTail = (stderrTail + chunk.toString()).slice(-2000);
    });

    const pending = new Map();
    let buffer = "";
    child.stdout.on("data", (chunk) => {
        buffer += chunk.toString();
        let nl;
        while ((nl = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, nl).trim();
            buffer = buffer.slice(nl + 1);
            if (!line) continue;
            let msg;
            try {
                msg = JSON.parse(line);
            } catch {
                continue; // a server that logs to stdout; not a protocol message
            }
            if (msg.id !== undefined && pending.has(msg.id)) {
                pending.get(msg.id)(msg);
                pending.delete(msg.id);
            }
        }
    });

    let exited = false;
    const exitPromise = new Promise((resolve) => {
        child.on("error", (err) => {
            exited = true;
            resolve(`could not start: ${err.message}`);
        });
        child.on("exit", (code) => {
            exited = true;
            resolve(`exited with code ${code}`);
        });
    });

    const request = (id, method, params) =>
        new Promise((resolve) => {
            pending.set(id, resolve);
            child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
        });

    const timer = new Promise((resolve) => setTimeout(() => resolve("timeout"), limit));
    const fail = (why) => {
        stop();
        const tail = stderrTail.trim().split("\n").slice(-5).join("\n");
        done(EXIT.failed, `MCP check failed: ${why}${tail ? `\n--- server stderr (last lines) ---\n${tail}` : ""}`);
    };

    const init = await Promise.race([
        request(1, "initialize", { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: CLIENT }),
        exitPromise,
        timer,
    ]);
    if (typeof init === "string") fail(`no answer to initialize (${init})`);
    if (init.error) fail(`initialize returned an error: ${init.error.message}`);
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);

    const names = [];
    let cursor;
    for (let page = 0, id = 2; page < 20; page++, id++) {
        const res = await Promise.race([request(id, "tools/list", cursor ? { cursor } : {}), exitPromise, timer]);
        if (typeof res === "string") fail(`no answer to tools/list (${res})`);
        if (res.error) fail(`tools/list returned an error: ${res.error.message}`);
        for (const t of res.result?.tools ?? []) names.push(t.name);
        cursor = res.result?.nextCursor;
        if (!cursor) break;
    }
    if (names.length === 0) fail("the server listed no tools");

    const probe = process.env.MCP_PROBE_TOOL;
    let probed = "";
    if (probe) {
        if (!names.includes(probe)) fail(`the server does not list ${probe}`);
        const retry = new RegExp(process.env.MCP_PROBE_RETRY_PATTERN || "$^", "i");
        for (let id = 100; ; id++) {
            const res = await Promise.race([request(id, "tools/call", { name: probe, arguments: {} }), exitPromise, timer]);
            if (typeof res === "string") fail(`no answer to ${probe} (${res})`);
            const text = (res.result?.content ?? []).map((c) => c.text ?? "").join(" ");
            if (res.error) fail(`${probe} returned an error: ${res.error.message}`);
            if (retry.test(text)) {
                await new Promise((resolve) => setTimeout(resolve, 1000));
                continue;
            }
            if (res.result?.isError) fail(`${probe} reported an error: ${text.slice(0, 300)}`);
            probed = ` ${probe} answered.`;
            break;
        }
    }
    if (!exited) stop();
    done(EXIT.ok, `MCP check passed: ${init.result?.serverInfo?.name ?? "server"} lists ${names.length} tools.${probed}`);
}

// --- http ---------------------------------------------------------------------

async function post(url, token, body, sessionId, signal) {
    const headers = {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        Authorization: `Bearer ${token}`,
    };
    if (sessionId) headers["Mcp-Session-Id"] = sessionId;
    if (body.method !== "initialize") headers["MCP-Protocol-Version"] = PROTOCOL;
    const res = await fetch(url, { method: "POST", headers, body: JSON.stringify(body), signal });
    const text = await res.text();
    let message = null;
    if ((res.headers.get("content-type") ?? "").includes("text/event-stream")) {
        for (const line of text.split(/\r?\n/)) {
            if (!line.startsWith("data:")) continue;
            try {
                const parsed = JSON.parse(line.slice(5).trim());
                if (parsed.id === body.id) message = parsed;
            } catch {
                // keep looking
            }
        }
    } else if (text) {
        try {
            message = JSON.parse(text);
        } catch {
            message = null;
        }
    }
    return { status: res.status, sessionId: res.headers.get("mcp-session-id"), message };
}

function networkFailure(err) {
    return err?.name === "AbortError" || err?.name === "TimeoutError" || err?.cause || err instanceof TypeError;
}

async function checkHttp() {
    const url = process.env.MCP_URL;
    const token = process.env.MCP_TOKEN;
    if (!url || !token) done(EXIT.usage, "check.mjs: MCP_URL and MCP_TOKEN are required.");
    const required = process.env.MCP_REQUIRE_TOOL;
    const signal = AbortSignal.timeout(timeoutMs(15000));

    try {
        const init = await post(
            url,
            token,
            { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: CLIENT } },
            null,
            signal,
        );
        if (init.status === 401 || init.status === 403) done(EXIT.rejected, `MCP check: the server refused the token (HTTP ${init.status}).`);
        if (init.status >= 400 || !init.message?.result) done(EXIT.failed, `MCP check failed: initialize answered HTTP ${init.status}.`);
        const session = init.sessionId;
        await fetch(url, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Accept: "application/json, text/event-stream",
                Authorization: `Bearer ${token}`,
                "MCP-Protocol-Version": PROTOCOL,
                ...(session ? { "Mcp-Session-Id": session } : {}),
            },
            body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
            signal,
        });
        const names = [];
        let cursor;
        for (let page = 0, id = 2; page < 20; page++, id++) {
            const res = await post(url, token, { jsonrpc: "2.0", id, method: "tools/list", params: cursor ? { cursor } : {} }, session, signal);
            if (res.status >= 400 || !res.message?.result) done(EXIT.failed, `MCP check failed: tools/list answered HTTP ${res.status}.`);
            for (const t of res.message.result.tools ?? []) names.push(t.name);
            cursor = res.message.result.nextCursor;
            if (!cursor) break;
        }
        if (required && !names.includes(required)) done(EXIT.failed, `MCP check failed: the server does not list ${required}.`);
        if (names.length === 0) done(EXIT.failed, "MCP check failed: the server listed no tools.");
        done(EXIT.ok, `MCP check passed: ${init.message.result.serverInfo?.name ?? "server"} lists ${names.length} tools.`);
    } catch (err) {
        if (networkFailure(err)) done(EXIT.unreachable, `MCP check: ${url} could not be reached.`);
        done(EXIT.failed, `MCP check failed: ${err.message}`);
    }
}

// --- token --------------------------------------------------------------------

// Part-DB's ApiTokenLevel: 1 READ_ONLY, 2 EDIT, 3 ADMIN, 4 FULL.
const LEVELS = { 1: "Read-Only", 2: "Edit", 3: "Admin", 4: "Full" };

async function checkToken() {
    const base = process.env.PARTDB_BASE;
    const token = process.env.MCP_TOKEN;
    if (!base || !token) done(EXIT.usage, "check.mjs: PARTDB_BASE and MCP_TOKEN are required.");
    const url = new URL("api/tokens/current", base.endsWith("/") ? base : `${base}/`);
    try {
        const res = await fetch(url, {
            headers: { Accept: "application/json", Authorization: `Bearer ${token}` },
            signal: AbortSignal.timeout(timeoutMs(10000)),
        });
        if (res.status === 401 || res.status === 403) done(EXIT.rejected, "Part-DB rejected the token (deleted, expired or mistyped).");
        if (!res.ok) done(EXIT.failed, `Part-DB answered HTTP ${res.status} to the token check.`);
        const body = await res.json();
        const raw = body?.level;
        const level = typeof raw === "number" ? raw : Number(String(raw ?? "").replace(/\D/g, "")) || null;
        const name = LEVELS[level] ?? String(raw);
        if (level === 1) done(EXIT.readOnly, "The token is Read-Only, so Claude can look up parts but not add them.");
        if (level !== 2) done(EXIT.scope, `The token's scope is ${name}; an Edit token is required${level > 2 ? `, as ${name} gives Claude more than it needs` : ""}.`);
        done(EXIT.ok, "Part-DB accepted the token (Edit).");
    } catch (err) {
        if (networkFailure(err)) done(EXIT.unreachable, `Part-DB at ${url.origin} could not be reached.`);
        done(EXIT.failed, `Token check failed: ${err.message}`);
    }
}

const mode = process.argv[2];
if (mode === "stdio") await checkStdio();
else if (mode === "http") await checkHttp();
else if (mode === "token") await checkToken();
else done(EXIT.usage, "usage: node check.mjs stdio|http|token (inputs in the environment; see the header)");
