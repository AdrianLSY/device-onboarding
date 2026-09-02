#!/bin/bash
set -e

# Keep the Mac awake while on AC so lid-closed work continues; sleep normally
# on battery.
#
# Why: closing the lid sleeps this Mac even on AC (verified 2026-09-02:
# 'Clamshell Sleep' Using AC), and a sleeping Mac executes nothing — so
# long-running Claude Code sessions die at lid close even when plugged in.
# Clamshell sleep is a forced transition: ordinary PreventSystemSleep /
# `caffeinate` assertions do NOT stop it (Claude Code's own `caffeinate -i`
# was running and did not). The only lever is pmset's system-wide
# SleepDisabled flag.
#
# AlDente cannot do this: its "Prevent Overcharging During Sleep" ->
# "Disable Sleep until Charge Limit" holds sleep off only UNTIL the charge
# limit is reached, and at-the-limit is the normal steady state on AC.
# ⚠ Set AlDente to "Stop Charging when Sleeping" instead, so it stops
# writing SleepDisabled — two writers on one global flag race each other.
# That setting also stays useful as a safety net: if the Mac ever does
# sleep on AC, it stops charging rather than overcharging.
#
# Design: SleepDisabled is GLOBAL (no -b/-c scoping), so per-power-source
# behavior comes from toggling it. A LaunchAgent RECONCILES state every
# 30 s (and at load) rather than reacting to plug/unplug events, because
# the one dangerous failure mode is "flag stuck at 1 on battery" — that
# would reintroduce the 4 %/hr lid-closed drain the sleep-freeze work
# eliminated. A state reconciler cannot get stuck: it self-heals from
# missed events, crashes, sleep/wake edges and third-party writes. A 30 s
# worst case of "unplugged but not yet sleeping" is harmless.
#
# Privilege: `pmset disablesleep` needs root, so the reconciler calls it
# through a NOPASSWD sudoers drop-in scoped to exactly two literal
# commands (no wildcards, no shell). This script does NOT install that
# drop-in — it prints the command for adrian to run, since that requires
# a password.
#
# Accepted trade-off (adrian, 2026-09-02): the Mac never sleeps while
# plugged in, including left closed and plugged in for days. Internal
# display is off in clamshell so this costs thermals/wear on a fanless
# M5 Air, not display power.
#
# Rollback: launchctl bootout the agent, rm the plist + reconciler + the
# sudoers drop-in, then `sudo pmset disablesleep 0`.

BIN_DIR="$HOME/.local/bin"
STATE_DIR="$HOME/.local/state"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="local.ac-stay-awake"
RECONCILER="$BIN_DIR/ac-stay-awake"
PLIST="$AGENT_DIR/$LABEL.plist"
SUDOERS_STAGE="$STATE_DIR/ac-stay-awake.sudoers"

mkdir -p "$BIN_DIR" "$STATE_DIR" "$AGENT_DIR"

# --- reconciler -----------------------------------------------------------
cat > "$RECONCILER" <<'EOF'
#!/bin/sh
# Managed by device-onboarding macos/setup/tweak/ac-stay-awake.sh — do not
# edit in place. Reconciles pmset's SleepDisabled flag with the current
# power source: AC -> 1 (no sleep, lid-closed work continues), battery -> 0
# (normal sleep + the claude freeze). Writes only on mismatch.
LOG="$HOME/.local/state/ac-stay-awake.log"

case "$(pmset -g batt 2>/dev/null | head -1)" in
    *"'AC Power'"*) WANT=1 ;;
    *)              WANT=0 ;;   # battery, or unknown -> fail safe to sleeping
esac

HAVE="$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2; exit}')"
[ -n "$HAVE" ] || HAVE=0
[ "$HAVE" = "$WANT" ] && exit 0

if sudo -n /usr/bin/pmset disablesleep "$WANT" 2>/dev/null; then
    echo "$(date '+%F %T') SleepDisabled $HAVE -> $WANT ($([ "$WANT" = 1 ] && echo AC || echo battery))" >> "$LOG"
else
    # Grant missing/revoked. Log once per hour, never error-spam, and never
    # fail the agent — the flag simply stays where macOS put it.
    STAMP="$HOME/.local/state/.ac-stay-awake-nogrant"
    if [ ! -f "$STAMP" ] || [ -n "$(find "$STAMP" -mmin +60 2>/dev/null)" ]; then
        echo "$(date '+%F %T') cannot set SleepDisabled=$WANT: sudoers grant missing" >> "$LOG"
        : > "$STAMP"
    fi
fi
EOF
chmod 755 "$RECONCILER"

# --- LaunchAgent ----------------------------------------------------------
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$RECONCILER</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>30</integer>
	<key>StandardErrorPath</key>
	<string>$STATE_DIR/ac-stay-awake.err</string>
</dict>
</plist>
EOF

# --- sudoers drop-in (staged; adrian installs it) -------------------------
cat > "$SUDOERS_STAGE" <<EOF
# Installed by device-onboarding macos/setup/tweak/ac-stay-awake.sh
# Scoped to exactly two literal commands: no wildcards, no shell, no
# privilege escalation path. Lets the ac-stay-awake reconciler toggle the
# system-wide sleep-disable flag without a password prompt.
$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1
EOF

# --- (re)load the agent ---------------------------------------------------
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "🟢 Loaded $LABEL (reconciles every 30s)."

if sudo -n /usr/bin/pmset disablesleep 0 2>/dev/null; then
    echo "🟢 sudoers grant present."
    "$RECONCILER"
    echo "   SleepDisabled now: $(pmset -g | awk '/SleepDisabled/{print $2}')"
else
    cat <<EOF

⚠️  One manual step left — the sudoers grant needs your password:

    sudo install -m 0440 -o root -g wheel "$SUDOERS_STAGE" /etc/sudoers.d/ac-stay-awake
    sudo visudo -c

Until then the agent runs but cannot change the flag (logged hourly to
$STATE_DIR/ac-stay-awake.log), and sleep behavior stays exactly as it is.
EOF
fi
