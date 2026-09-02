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
# commands (no wildcards, no shell). This script installs that drop-in
# itself (prompting for a password, per the repo's sudo-using tweak
# convention), skipping when the grant is already in place. The file is
# validated standalone with `visudo -c -f` BEFORE installation and the
# whole set re-validated after — a malformed /etc/sudoers.d entry can
# break sudo system-wide, so a failed check removes it again.
#
# Lid closed on AC: because the Mac no longer sleeps, macOS's lock-on-sleep
# never fires — the session would sit UNLOCKED behind a closed lid. The
# reconciler therefore runs `pmset displaysleepnow` on the lid-close
# transition, which powers the panel down and (with this Mac's screen lock
# set to "immediate") locks the session. Skipped when an external display is
# attached, i.e. real clamshell-desktop use.
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
# edit in place. Two jobs, both idempotent:
#   1. Reconcile pmset's SleepDisabled flag with the power source:
#      AC -> 1 (no sleep, lid-closed work continues), battery -> 0 (normal
#      sleep + the claude freeze). Writes only on mismatch.
#   2. On the lid-close transition while on AC, turn the display off, which
#      locks the session.
LOG="$HOME/.local/state/ac-stay-awake.log"

# --- 1. sleep flag --------------------------------------------------------
case "$(pmset -g batt 2>/dev/null | head -1)" in
    *"'AC Power'"*) WANT=1 ;;
    *)              WANT=0 ;;   # battery, or unknown -> fail safe to sleeping
esac

HAVE="$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2; exit}')"
[ -n "$HAVE" ] || HAVE=0

if [ "$HAVE" != "$WANT" ]; then
    if sudo -n /usr/bin/pmset disablesleep "$WANT" 2>/dev/null; then
        echo "$(date '+%F %T') SleepDisabled $HAVE -> $WANT ($([ "$WANT" = 1 ] && echo AC || echo battery))" >> "$LOG"
    else
        # Grant missing/revoked. Log at most hourly, never error-spam, never
        # fail the agent — the flag simply stays where macOS put it.
        STAMP="$HOME/.local/state/.ac-stay-awake-nogrant"
        if [ ! -f "$STAMP" ] || [ -n "$(find "$STAMP" -mmin +60 2>/dev/null)" ]; then
            echo "$(date '+%F %T') cannot set SleepDisabled=$WANT: sudoers grant missing" >> "$LOG"
            : > "$STAMP"
        fi
    fi
fi

# --- 2. lid closed on AC: display off + lock ------------------------------
# With sleep disabled, closing the lid no longer sleeps the Mac, so macOS's
# normal lock-on-sleep never fires and the session would sit UNLOCKED behind
# a closed lid. `pmset displaysleepnow` powers the panel down, and because
# this Mac's screen lock is "immediate" (verify: `sysadminctl -screenLock
# status`; the tweak warns if it is not) display-off locks the session.
# Fires once per lid-close transition, not every poll.
LIDSTAMP="$HOME/.local/state/.ac-stay-awake-lid"
LID="$(ioreg -r -k AppleClamshellState 2>/dev/null | awk -F'= ' '/AppleClamshellState/{print $2; exit}')"

if [ "$LID" = "Yes" ] && [ "$WANT" = 1 ]; then
    if [ ! -f "$LIDSTAMP" ]; then
        : > "$LIDSTAMP"
        # Skip in true clamshell mode (external display attached): the user
        # is working on that screen, so blanking and locking it is wrong.
        EXT="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Connection Type: [^I]')"
        if [ "${EXT:-0}" -eq 0 ]; then
            pmset displaysleepnow 2>/dev/null &&
                echo "$(date '+%F %T') lid closed on AC: display off, session locked" >> "$LOG"
        else
            echo "$(date '+%F %T') lid closed on AC: external display present, left awake" >> "$LOG"
        fi
    fi
elif [ "$LID" != "Yes" ]; then
    rm -f "$LIDSTAMP"
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

# The lock guarantee depends on the screen lock being immediate. Do not try
# to set it silently (it needs a password); verify loudly instead.
if sysadminctl -screenLock status 2>&1 | grep -q 'immediate'; then
    echo "🟢 Screen lock is immediate — display-off will lock the session."
else
    echo "🔴 Screen lock is NOT immediate. Lid-closed-on-AC would turn the"
    echo "   display off WITHOUT locking. Fix in System Settings > Lock Screen"
    echo "   (\"Require password ... immediately\") before relying on this."
fi

SUDOERS_DEST=/etc/sudoers.d/ac-stay-awake

if sudo -n /usr/bin/pmset disablesleep 0 2>/dev/null; then
    echo "⏭️  sudoers grant already present."
else
    # Validate the drop-in STANDALONE before installing it. A malformed file
    # in /etc/sudoers.d can break sudo system-wide, so never install first
    # and check afterwards. `visudo -c -f` works unprivileged.
    if ! visudo -c -f "$SUDOERS_STAGE" >/dev/null 2>&1; then
        echo "🔴 Refusing to install: $SUDOERS_STAGE failed sudoers validation." >&2
        exit 1
    fi
    echo "🔑 Installing sudoers grant — your password is required:"
    sudo install -m 0440 -o root -g wheel "$SUDOERS_STAGE" "$SUDOERS_DEST"
    if sudo visudo -c >/dev/null 2>&1; then
        echo "🟢 sudoers grant installed and the full sudoers set validates."
    else
        # Leaving a bad drop-in in place would be worse than not having it.
        sudo rm -f "$SUDOERS_DEST"
        echo "🔴 Post-install validation failed; drop-in removed. sudo is intact." >&2
        exit 1
    fi
fi

"$RECONCILER"
echo "   Power source: $(pmset -g batt | head -1 | sed -E "s/.*from '([^']*)'.*/\\1/")"
echo "   SleepDisabled now: $(pmset -g | awk '/SleepDisabled/{print $2}')"
