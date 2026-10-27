#!/bin/bash
set -e

# Remote Login (sshd), key-only, so the work laptop can reach this Mac over the
# tailnet with the personal key (sites_ad_p3).
#
# The tailnet lets every member reach every port of every other member, so a
# drop-in turns password and keyboard-interactive login off. It is written
# before Remote Login is turned on, so sshd never accepts a password. launchd
# starts sshd once per connection, so a new config applies from the next login
# with nothing to reload. That also means a broken config refuses every login,
# so the drop-in is checked with `sshd -t` and put back if it fails.
#
# The authorized key is the public half of ~/.ssh/sites_ad_p3_ed25519, kept here
# so the Mac being reached doesn't need the key itself. It is appended to
# ~/.ssh/authorized_keys when missing; other lines there are left alone.
#
# sudo runs only when the drop-in or Remote Login needs changing, so a re-run on
# a set-up Mac changes nothing and asks for no password.

# Backups reuse lib/link.sh's _link_backup_path. Repo root is three levels up.
# shellcheck source=lib/link.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/lib/link.sh"

AUTHORIZED_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPMlo8TW3RmsPRugzbbcXMb20eoil81KFmXiRshXAdjM sites.ad.p3@gmail.com'
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

# 010 sorts before macOS's own 100-macos.conf, and sshd keeps the first value it
# reads for each keyword.
DROPIN=/etc/ssh/sshd_config.d/010-key-only.conf
DROPIN_CONTENT='# Written by device-onboarding macos/setup/tweak/sshd.sh; edit that and re-run it.
PasswordAuthentication no
KbdInteractiveAuthentication no'

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if ! grep -qF "$(cut -d' ' -f2 <<<"$AUTHORIZED_KEY")" "$AUTHORIZED_KEYS" 2>/dev/null; then
    # Start on a new line if the file doesn't end in one.
    if [ -s "$AUTHORIZED_KEYS" ] && [ -n "$(tail -c1 "$AUTHORIZED_KEYS")" ]; then
        echo >>"$AUTHORIZED_KEYS"
    fi
    (umask 077 && printf '%s\n' "$AUTHORIZED_KEY" >>"$AUTHORIZED_KEYS")
    echo "sshd: added the sites_ad_p3 key to $AUTHORIZED_KEYS"
fi
chmod 600 "$AUTHORIZED_KEYS"

if [ "$(cat "$DROPIN" 2>/dev/null)" != "$DROPIN_CONTENT" ]; then
    BACKUP=
    if [ -e "$DROPIN" ]; then
        BACKUP="$(_link_backup_path "$DROPIN")"
        sudo mv "$DROPIN" "$BACKUP"
        echo "sshd: backed up $DROPIN -> $BACKUP"
    fi
    printf '%s\n' "$DROPIN_CONTENT" | sudo tee "$DROPIN" >/dev/null
    sudo chmod 644 "$DROPIN"
    # macOS makes the host keys the first time Remote Login starts sshd, and
    # `sshd -t` exits with "no hostkeys available" without them. Make any that
    # are missing now, as launchd's wrapper would; existing keys are kept.
    if ! sudo ssh-keygen -A || ! sudo sshd -t; then
        sudo rm -f "$DROPIN"
        if [ -n "$BACKUP" ]; then
            sudo mv "$BACKUP" "$DROPIN"
        fi
        echo "🔴 sshd: config validation failed; took $DROPIN back out" >&2
        exit 1
    fi
    echo "sshd: wrote $DROPIN (key-only login)"
fi

# Remote Login is on when launchd has the sshd job both enabled and loaded.
remote_login_on() {
    launchctl print-disabled system 2>/dev/null | grep -q '"com.openssh.sshd" => enabled' &&
        launchctl print system/com.openssh.sshd >/dev/null 2>&1
}

if ! remote_login_on; then
    # Fails without Full Disk Access for the terminal; checked again below.
    sudo systemsetup -setremotelogin on >/dev/null 2>&1 || true
fi
if ! remote_login_on; then
    echo "🔴 sshd: Remote Login is off and systemsetup couldn't turn it on (it needs Full Disk Access for this terminal)." >&2
    echo "   Turn it on in System Settings > General > Sharing > Remote Login, then re-run this tweak." >&2
    exit 1
fi

echo "🟢 sshd: Remote Login is on, key-only. From the work laptop: ssh -i ~/.ssh/sites_ad_p3_ed25519 $(id -un)@<this Mac's tailnet name>"
