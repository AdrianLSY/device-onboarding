#!/bin/bash
set -euo pipefail

# --prepare-only stages the installed files without touching a running job.
prepare_only=false
case "${1:-}" in
    --prepare-only) prepare_only=true ;;
    '') ;;
    *) echo "Usage: $0 [--prepare-only]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Unexpected arguments" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || { echo "Power policy requires macOS" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run as the signed-in user, not root" >&2; exit 1; }

repo_dir="$(cd "$(dirname "$0")/../../.." && pwd)"
# Reuse the repository's non-colliding backup naming convention.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../lib/link.sh
source "$repo_dir/lib/link.sh"
source_file="$repo_dir/macos/power-policy/PowerPolicy.swift"
install_dir="$HOME/Library/Application Support/device-power-policy"
binary="$install_dir/power-policy"
hash_file="$install_dir/source.sha256"
activated_hash="$install_dir/activated-plist.sha256"
activated_plist="$install_dir/activated.plist"
label=com.adrian.power-policy
plist="$HOME/Library/LaunchAgents/$label.plist"
log_file="$HOME/Library/Logs/device-power-policy.log"
target="gui/$(id -u)/$label"

[ -f "$source_file" ] || { echo "Missing source: $source_file" >&2; exit 1; }
for value in 0 1; do
    if ! /usr/bin/sudo -n -l /usr/bin/pmset disablesleep "$value" >/dev/null 2>&1; then
        echo "Missing password-free authorization: /usr/bin/pmset disablesleep $value" >&2
        echo "In Vorssaint, enable Keep Awake's closed-lid support once with administrator approval, then retry." >&2
        echo "This installer does not create or broaden sudo rules." >&2
        exit 1
    fi
done
lock_status="$(/usr/sbin/sysadminctl -screenLock status 2>&1)"
if [[ "$lock_status" != *"screenLock delay is immediate"* ]]; then
    echo "Require the password immediately after the display turns off in System Settings > Lock Screen, then retry." >&2
    printf '%s\n' "$lock_status" >&2
    exit 1
fi

mkdir -p "$install_dir" "$(dirname "$plist")" "$(dirname "$log_file")"
stage="$(mktemp -d "$install_dir/.stage.XXXXXX")"
changed_paths=()
backups=()
transaction=false
was_loaded=false
stopped=false
bootstrap_attempted=false
reload_attempted=false
/bin/launchctl print "$target" >/dev/null 2>&1 && was_loaded=true

file_hash() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }
# A prepared plist may differ from the definition launchd actually loaded.
if $was_loaded; then
    if [ -f "$activated_plist" ] &&
        [ "$(file_hash "$activated_plist")" = "$(cat "$activated_hash" 2>/dev/null || true)" ]; then
        cp "$activated_plist" "$stage/previous-agent.plist"
    elif [ -f "$plist" ]; then
        cp "$plist" "$stage/previous-agent.plist"
    fi
fi

bootstrap_retry() {
    local definition="$1" attempt output result
    for attempt in 1 2 3 4 5; do
        if output="$(/bin/launchctl bootstrap "gui/$(id -u)" "$definition" 2>&1)"; then
            [ -z "$output" ] || printf '%s\n' "$output"
            return 0
        else result=$?; fi
        # EIO can briefly mean the previous registration is still tearing down.
        if [ "$result" -ne 5 ] || [ "$attempt" -eq 5 ]; then
            printf '%s\n' "$output" >&2
            return "$result"
        fi
        sleep 0.2
    done
}

finish() {
    local result=$? i dst previous displaced
    trap - EXIT
    if [ "$result" -ne 0 ] && $transaction; then
        echo "Installation failed; restoring the previous managed files." >&2
        if $bootstrap_attempted; then
            /bin/launchctl bootout "$target" >/dev/null 2>&1 || true
        fi
        for ((i=${#changed_paths[@]}-1; i>=0; i--)); do
            dst="${changed_paths[$i]}"
            previous="${backups[$i]}"
            if [ -e "$dst" ] || [ -L "$dst" ]; then
                displaced="$(_link_backup_path "$dst.failed")"
                mv "$dst" "$displaced" || true
            fi
            if [ -n "$previous" ]; then
                mv "$previous" "$dst" || echo "Restore failed: $previous -> $dst" >&2
            fi
        done
        if $reload_attempted; then
            /bin/launchctl kickstart -k "$target" ||
                echo "Could not restart the previous executable; inspect launchctl and $log_file" >&2
        elif $stopped && $was_loaded && [ -f "$stage/previous-agent.plist" ]; then
            deploy_file "$stage/previous-agent.plist" "$plist" 644
            bootstrap_retry "$plist" ||
                echo "Could not restart the previous job; inspect launchctl and $log_file" >&2
        fi
    fi
    # Only the uniquely-created staging directory is disposable.
    rm -rf "$stage"
    exit "$result"
}
trap finish EXIT

source_hash="$(file_hash "$source_file")"
check_binary="$binary"
if [ ! -x "$binary" ] || [ -L "$binary" ] ||
    [ "$(cat "$hash_file" 2>/dev/null || true)" != "$source_hash" ]; then
    /usr/bin/xcrun swiftc -O -parse-as-library "$source_file" -o "$stage/power-policy"
    check_binary="$stage/power-policy"
fi
"$check_binary" --check
"$check_binary" --status
printf '%s\n' "$source_hash" > "$stage/source.sha256"

xml_escape() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    printf '%s' "$text"
}
cat > "$stage/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$(xml_escape "$binary")</string><string>--run</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>$(xml_escape "$log_file")</string>
<key>StandardErrorPath</key><string>$(xml_escape "$log_file")</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$stage/agent.plist"
definition_hash="$(file_hash "$stage/agent.plist")"
definition_loaded=false
if [ "$definition_hash" = "$(cat "$activated_hash" 2>/dev/null || true)" ]; then definition_loaded=true; fi

deploy_file() {
    local src="$1" dst="$2" mode="$3" previous=''
    if [ ! -L "$dst" ] && [ -f "$dst" ] && cmp -s "$src" "$dst" &&
        [ "$(/usr/bin/stat -f '%Lp' "$dst")" = "$mode" ]; then return; fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        previous="$(_link_backup_path "$dst")"
        mv "$dst" "$previous"
        echo "Backed up $dst to $previous"
    fi
    changed_paths+=("$dst")
    backups+=("$previous")
    chmod "$mode" "$src"
    mv "$src" "$dst"
}
transaction=true
if [ "$check_binary" != "$binary" ]; then deploy_file "$check_binary" "$binary" 755; fi
deploy_file "$stage/source.sha256" "$hash_file" 644
deploy_file "$stage/agent.plist" "$plist" 644

if $prepare_only; then
    echo "Prepared $binary and $plist; the running power policy was not changed."
else
    # Restart even if files match: an earlier --prepare-only may have replaced
    # the installed binary while the loaded process kept its previous inode.
    if $was_loaded && $definition_loaded; then
        # The job definition is unchanged: restart its executable directly.
        # Unregistering and immediately registering the same launchd job can
        # race service teardown and fail with bootstrap error 5.
        reload_attempted=true
        /bin/launchctl kickstart -k "$target"
    else
        if $was_loaded; then
            /bin/launchctl bootout "$target"
            stopped=true
        fi
        bootstrap_attempted=true
        bootstrap_retry "$plist"
    fi
    # Record only an activated definition; --prepare-only never updates this.
    cp "$plist" "$stage/activated.plist"
    printf '%s\n' "$definition_hash" > "$stage/activated-plist.sha256"
    deploy_file "$stage/activated.plist" "$activated_plist" 644
    deploy_file "$stage/activated-plist.sha256" "$activated_hash" 644
    echo "Power policy loaded. Existing awake docked sessions are preserved; log: $log_file"
fi
transaction=false
