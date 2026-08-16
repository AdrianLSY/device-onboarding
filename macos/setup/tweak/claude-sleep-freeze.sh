#!/bin/bash
set -e

# Freeze Claude Code CLI processes while the Mac sleeps; thaw them on wake.
#
# Why: each Claude Code session (process name `claude`) holds ~30 established
# TLS connections to Anthropic. Lid-closed, that overflows the Wi-Fi chip's
# TCP-keepalive offload budget, so the SoC dark-wakes ~50×/hr for ~45 s at a
# time — measured 4.3 %/hr overnight battery drain vs the ~1 %/hr no-Claude
# baseline (three-night bisection, 2026-07/08; Tailscale exonerated). Freezing
# the processes lets the server side drop the connections: dark wakes collapse
# to empty ~5 s bounces while sessions keep full in-memory state and resume on
# wake. Chosen over `pmset -b tcpkeepalive 0` deliberately — that would also
# work but disables Find My during battery sleep.
#
# Mechanism: Homebrew `sleepwatcher` (installed by the brew module) runs as a
# user LaunchAgent (RunAtLoad + KeepAlive) executing ~/.sleep and ~/.wakeup on
# system sleep/wake. The hooks signal ONLY processes named exactly `claude`
# (case-sensitive `pkill -x`): every Claude Code CLI, wherever installed —
# never the `Claude` desktop shell or `Claude Helper*`. Dark wakes cannot
# mis-fire the wakeup hook: sleepwatcher uses the legacy
# IORegisterForSystemPower API, which macOS notifies only on full
# (user-visible) sleep/wake transitions. sleepwatcher gives hooks 15 s;
# pkill takes milliseconds.
#
# Known trade-off (accepted): a session streaming a response at the moment of
# lid-close has that one request error on thaw; the session itself survives
# and recovers on the next prompt.
#
# Idempotent + non-destructive per tweak rules: hooks are only (re)written
# when content differs; a pre-existing foreign ~/.sleep or ~/.wakeup is moved
# to <file>.bak.<timestamp>, never deleted. Freeze/thaw actions append to
# ~/.local/state/sleepwatcher.log for morning-after audits.

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
# Managed by device-onboarding macos/setup/tweak/claude-sleep-freeze.sh — do
# not edit in place; edit the tweak and re-run it. Freezes Claude Code CLIs
# (exact process name 'claude') for the duration of system sleep.
LOG="$HOME/.local/state/sleepwatcher.log"
N="$(pgrep -x claude | wc -l | tr -d ' ')"
echo "$(date '+%F %T') .sleep: freezing $N claude process(es)" >> "$LOG"
pkill -STOP -x claude || true
EOF

install_hook "$HOME/.wakeup" <<'EOF'
#!/bin/sh
# Managed by device-onboarding macos/setup/tweak/claude-sleep-freeze.sh — do
# not edit in place; edit the tweak and re-run it. Thaws Claude Code CLIs
# (exact process name 'claude') frozen by ~/.sleep.
LOG="$HOME/.local/state/sleepwatcher.log"
N="$(pgrep -x claude | wc -l | tr -d ' ')"
echo "$(date '+%F %T') .wakeup: thawing $N claude process(es)" >> "$LOG"
pkill -CONT -x claude || true
EOF

# Register + start the LaunchAgent (idempotent: restart bootstraps the service
# on first run and picks up hook changes on re-runs). The generated plist runs
# `sleepwatcher -V -s $HOME/.sleep -w $HOME/.wakeup` with RunAtLoad+KeepAlive,
# so the watcher survives reboots without further action.
brew services restart sleepwatcher
