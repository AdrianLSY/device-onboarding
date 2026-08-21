#!/bin/bash
set -e

# Freeze third-party network apps while the Mac sleeps; thaw them on wake.
# (Generalizes the original Claude-only freeze — see git history of
# claude-sleep-freeze.sh.)
#
# Why: Claude Code CLI sessions hold ~30+ established TLS connections and
# poll on timers. Lid-closed that overflowed the Wi-Fi chip's keepalive
# offload budget and dark-woke the SoC ~50x/hr — 4.3 %/hr overnight drain
# (2026-07) vs ~0.1 %/hr once frozen (2026-08-16 acceptance). Freezing works
# here because the driver is the app's own OUTBOUND activity, which SIGSTOP
# genuinely stops.
#
# ⚠ SCOPE LIMIT — DO NOT naively add GUI apps to this list. SIGSTOP does
# NOT close sockets: a stopped process keeps every socket ESTABLISHED
# (verified 2026-08-21: Spotify held in state T for 40 s kept all 4 sockets
# identical), and during sleep the Wi-Fi chip's TCP KeepAlive Offload engine
# answers keepalives on the host's behalf, so remote peers never drop them
# and INBOUND pushes still wake the SoC. An expansion to Claude.app,
# Vivaldi, Spotify, Steam, Dropbox and Thunderbird was implemented and
# tested over two full nights (2026-08-19/20, 08-20/21): the storm was
# unchanged (~2,100 dark wakes, 1.4–3.0 %/hr, wake codes E_TKO_TCP_DATA),
# so it was reverted. Inbound-push storms need the sockets CLOSED (quit the
# app / close the push tabs) or `pmset -b tcpkeepalive 0` — not freezing.
#
# Policy (deny-by-default): ONLY processes matched by the FREEZE TARGETS
# below are ever signaled. Everything else is untouchable by construction.
# Find My keeps working during sleep — two independent layers:
#   1. Its daemons (apsd, searchpartyd, findmydeviced, identityservicesd,
#      bluetoothd) are Apple system processes and are never listed.
#   2. They run as root/system users, which this user-level hook cannot
#      signal at all (EPERM), even in a bug scenario.
# pmset network settings (tcpkeepalive/powernap/womp) are never touched.
#
# Deliberate NON-targets, with reasons — do not add these:
#   - Apple system daemons: Find My / push / iMessage path (see above).
#   - Tailscale: 1 connection, measured harmless (2026-08-14 night at
#     1.0 %/hr with the full tailnet up); freezing the VPN risks wedged
#     networking on wake.
#   - Cryptomator + webdavfs_agent: loopback-only mount plumbing; freezing
#     filesystem agents risks I/O hangs for anything touching the mount.
#   - Every GUI app (browsers, Spotify, Steam, Dropbox, Thunderbird, and
#     the Claude.app shell): freezing them is measurably useless against
#     inbound pushes (see SCOPE LIMIT above) and adds thaw risk for zero
#     benefit.
#   - AlDente: charge limiting must keep working while asleep on AC.
#
# GUI-thaw risk, accepted (adrian, 2026-08-18): SIGSTOP on GUI apps is
# slightly riskier than on a headless CLI (XPC peers, watchdogs). The
# freeze window is bracketed by system sleep — peer processes and watchdog
# timers are suspended too — and the wakeup hook thaws everything within
# ~1 s of wake, before user interaction is realistic. Any app that
# misbehaves on thaw gets removed from the list; the list is the knob.
#
# Observability: every freeze/thaw block logs one line per target with the
# matched-PID count to ~/.local/state/sleepwatcher.log. A target showing
# "0 pid(s)" while its app is open means the pattern rotted (app renamed
# its binary) — fix the list.
#
# ⚠ Testing: dry-run hook changes from a neutral launchd context
# (`launchctl submit -l probe -- /bin/sh <script>`), never from a
# Claude-spawned shell — those are proc-info-blind to Claude-family
# processes and report false zero-matches.
#
# Idempotent + non-destructive per tweak rules: hooks are only (re)written
# when content differs; a pre-existing foreign ~/.sleep or ~/.wakeup is
# moved to <file>.bak.<timestamp>, never deleted.

mkdir -p "$HOME/.local/state"

# Backup-then-write in the _link_one/zsh.sh spirit: no-op when content is
# already ours; timestamped backup (numeric suffix if taken) when foreign.
install_hook() {
    local dst="$1" tmp
    tmp="$(mktemp)"
    cat > "$tmp"                      # hook body arrives on stdin
    chmod 700 "$tmp"
    if [[ -e "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        chmod 700 "$dst"              # converge perms even when content matches
        echo "⏭️  $(basename "$dst") already up to date."
        return 0
    fi
    if [[ -e "$dst" || -L "$dst" ]]; then
        local bak n=1
        bak="$dst.bak.$(date +%Y%m%d%H%M%S)"
        while [[ -e "$bak" ]]; do bak="$dst.bak.$(date +%Y%m%d%H%M%S).$n"; ((n++)); done
        mv "$dst" "$bak"
        echo "📦 Backed up existing $(basename "$dst") to $(basename "$bak")."
    fi
    mv "$tmp" "$dst"
    echo "🟢 Wrote $(basename "$dst")."
}

install_hook "$HOME/.sleep" <<'EOF'
#!/bin/sh
# Managed by device-onboarding macos/setup/tweak/sleep-freeze.sh — do not
# edit in place; edit the tweak and re-run it. Freezes the Claude Code CLI
# for the duration of system sleep. Deny-by-default: only processes matched
# below are signaled; Apple daemons (incl. the Find My path) are never
# listed and are unsignalable from this user-level hook anyway.
LOG="$HOME/.local/state/sleepwatcher.log"
TS="$(date '+%F %T')"

# Exact-name CLI targets (proven case; see SCOPE LIMIT before adding more)
# shellcheck disable=SC2043
for NAME in claude; do
    N="$(pgrep -x "$NAME" | wc -l | tr -d ' ')"
    echo "$TS .sleep freezing name:$NAME: $N pid(s)" >> "$LOG"
    pkill -STOP -x "$NAME" 2>/dev/null || true
done

echo "$TS .sleep block done" >> "$LOG"
EOF

install_hook "$HOME/.wakeup" <<'EOF'
#!/bin/sh
# Managed by device-onboarding macos/setup/tweak/sleep-freeze.sh — do not
# edit in place; edit the tweak and re-run it. Thaws everything ~/.sleep
# froze. Same deny-by-default target list; SIGCONT on a running process is
# a harmless no-op.
LOG="$HOME/.local/state/sleepwatcher.log"
TS="$(date '+%F %T')"

# shellcheck disable=SC2043
for NAME in claude; do
    N="$(pgrep -x "$NAME" | wc -l | tr -d ' ')"
    echo "$TS .wakeup thawing name:$NAME: $N pid(s)" >> "$LOG"
    pkill -CONT -x "$NAME" 2>/dev/null || true
done

echo "$TS .wakeup block done" >> "$LOG"
EOF

# Register + start the LaunchAgent (idempotent: restart bootstraps the service
# on first run and picks up hook changes on re-runs). The generated plist runs
# `sleepwatcher -V -s $HOME/.sleep -w $HOME/.wakeup` with RunAtLoad+KeepAlive,
# so the watcher survives reboots without further action.
brew services restart sleepwatcher
