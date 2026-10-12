#!/bin/bash
set -e

# GitHub SSH for git that runs OUTSIDE an interactive zsh: Claude Code, scripts,
# launchd jobs, editors. Those never load the `git` wrapper in
# zsh/rc.d/git-multi-account.zsh, and ssh-keypick deliberately leaves github.com
# alone (~/.ssh/keypick.exclude), so without this nothing offers a key and every
# clone and push fails with "Permission denied (publickey)".
#
# Two pieces; once both are in place, a second run changes nothing:
#   1. ~/.ssh/config gets a `Host github.com ssh.github.com` stanza that defaults
#      to the work account's key. It sits OUTSIDE the keypick managed block, so
#      `ssh-keypick install` keeps it.
#   2. ~/.gitconfig gets an includeIf on remotes of the personal account. The
#      included ~/.config/git/github-personal.gitconfig sets core.sshCommand to
#      `ssh -i <personal key>`; -i is offered ahead of the IdentityFile above, so
#      GitHub sees the personal account for those repos. (`hasconfig:` needs
#      git 2.36 or later.)
#
# At clone time the interactive wrapper still stamps each repo's own
# core.sshCommand, identity and signing config, which win over both pieces.
# Each account's key is read from that wrapper, the one place it is set.

# Backups reuse lib/link.sh's _link_backup_path (non-colliding <file>.bak.<timestamp>).
# shellcheck source=lib/link.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/lib/link.sh"

TIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$TIER_DIR/zsh/rc.d/git-multi-account.zsh"

WORK_ACCOUNT=Adrian-LSY      # default for github.com
PERSONAL_ACCOUNT=AdrianLSY   # selected by remote URL

SSH_CONFIG="$HOME/.ssh/config"
KEYPICK_BEGIN="# >>> keypick managed block (do not edit between markers) >>>"
KEYPICK_END="# <<< keypick managed block <<<"

PERSONAL_GITCONFIG="$HOME/.config/git/github-personal.gitconfig"
# shellcheck disable=SC2088  # git expands the ~ itself; keep it literal
PERSONAL_GITCONFIG_REF='~/.config/git/github-personal.gitconfig'
INCLUDE_KEY="includeIf.hasconfig:remote.*.url:git@github.com:$PERSONAL_ACCOUNT/**.path"

# Echo the account's private key path, ~-abbreviated, as the wrapper defines it.
# zsh -f skips the rc files, so only the wrapper's function definitions load.
key_for() {
    local key
    key="$(zsh -fc 'source "$1" && __git_ssh_key_for_account "$2"' zsh "$WRAPPER" "$1")"
    if [ -z "$key" ]; then
        echo "git-multi-account: no key for $1 in $WRAPPER" >&2
        return 1
    fi
    case "$key" in
        "$HOME"/*) printf '%s\n' "~${key#"$HOME"}" ;;
        *)         printf '%s\n' "$key" ;;
    esac
}

expand_tilde() {
    case "$1" in
        "~"/*) printf '%s\n' "$HOME/${1#"~/"}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# Copy <file> to a non-colliding backup before changing it.
backup() {
    local bak
    bak="$(_link_backup_path "$1")"
    cp -p "$1" "$bak"
    echo "git-multi-account: backed up $1 -> $bak"
}

warn_if_missing() {
    [ -f "$(expand_tilde "$1")" ] ||
        echo "git-multi-account: $1 is not on this Mac yet; add it to ~/.ssh and this config starts working"
}

WORK_KEY="$(key_for "$WORK_ACCOUNT")"
PERSONAL_KEY="$(key_for "$PERSONAL_ACCOUNT")"

# ── 1. ~/.ssh/config: default github.com to the work key ──

# True if a Host (or Match host) line outside the keypick managed block already
# names github.com. Any such stanza is the user's and is never rewritten.
has_github_stanza() {
    [ -f "$SSH_CONFIG" ] || return 1
    awk -v b="$KEYPICK_BEGIN" -v e="$KEYPICK_END" '
        $0==b { inblk=1; next }
        $0==e { inblk=0; next }
        inblk { next }
        tolower($1)=="host" {
            for (i=2; i<=NF; i++) if (tolower($i)=="github.com") found=1
        }
        tolower($1)=="match" {
            for (i=2; i<NF; i++) if (tolower($i)=="host") {
                n=split(tolower($(i+1)), h, ",")
                for (j=1; j<=n; j++) if (h[j]=="github.com") found=1
            }
        }
        END { exit !found }
    ' "$SSH_CONFIG"
}

GITHUB_STANZA="# GitHub: two accounts share this host, so ssh-keypick leaves github.com alone
# and ssh would offer no key to git run outside an interactive zsh. Default to
# the work account ($WORK_ACCOUNT); $PERSONAL_ACCOUNT/* repos switch to the personal key
# through an includeIf in ~/.gitconfig. Written by device-onboarding's git-multi-account
# tweak, outside the keypick managed block so \`ssh-keypick install\` keeps it.
Host github.com ssh.github.com
    IdentityFile $WORK_KEY
    IdentitiesOnly yes"

if has_github_stanza; then
    echo "git-multi-account: $SSH_CONFIG already has a github.com stanza; left alone"
else
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    tmp="$(mktemp "$SSH_CONFIG.XXXXXX")"
    if [ -f "$SSH_CONFIG" ]; then
        backup "$SSH_CONFIG"
        if grep -qxF "$KEYPICK_END" "$SSH_CONFIG"; then
            # Directly after the managed block, ahead of any `Host *` defaults.
            STANZA="$GITHUB_STANZA" awk -v e="$KEYPICK_END" '
                { print }
                $0==e && !done { print ""; print ENVIRON["STANZA"]; done=1 }
            ' "$SSH_CONFIG" >"$tmp"
        else
            { printf '%s\n\n' "$GITHUB_STANZA"; cat "$SSH_CONFIG"; } >"$tmp"
        fi
    else
        printf '%s\n' "$GITHUB_STANZA" >"$tmp"
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$SSH_CONFIG"
    echo "git-multi-account: added the github.com stanza to $SSH_CONFIG"
fi
warn_if_missing "$WORK_KEY"

# ── 2. global git config: personal key for the personal account's remotes ──

SSH_COMMAND="ssh -i $PERSONAL_KEY -o IdentitiesOnly=yes"

if [ "$(git config --file "$PERSONAL_GITCONFIG" --get core.sshCommand 2>/dev/null)" = "$SSH_COMMAND" ]; then
    echo "git-multi-account: $PERSONAL_GITCONFIG already set; left alone"
else
    if [ -f "$PERSONAL_GITCONFIG" ]; then
        backup "$PERSONAL_GITCONFIG"
    else
        mkdir -p "$(dirname "$PERSONAL_GITCONFIG")"
        cat >"$PERSONAL_GITCONFIG" <<EOF
# Included by ~/.gitconfig for repos whose remote is the personal $PERSONAL_ACCOUNT
# GitHub account. ~/.ssh/config defaults github.com to the work key
# ($WORK_ACCOUNT); -i puts the personal key ahead of it, so GitHub
# authenticates these repos as $PERSONAL_ACCOUNT. Written by device-onboarding's
# git-multi-account tweak.
EOF
    fi
    git config --file "$PERSONAL_GITCONFIG" core.sshCommand "$SSH_COMMAND"
    echo "git-multi-account: set core.sshCommand in $PERSONAL_GITCONFIG"
fi

# The include counts as present whether it names the file as ~/… or by full path.
include_present() {
    local path
    while IFS= read -r path; do
        [ "$(expand_tilde "$path")" = "$PERSONAL_GITCONFIG" ] && return 0
    done < <(git config --global --get-all "$INCLUDE_KEY" 2>/dev/null)
    return 1
}

if include_present; then
    echo "git-multi-account: ~/.gitconfig already includes $PERSONAL_GITCONFIG_REF; left alone"
else
    [ -f "$HOME/.gitconfig" ] && backup "$HOME/.gitconfig"
    git config --global --add "$INCLUDE_KEY" "$PERSONAL_GITCONFIG_REF"
    echo "git-multi-account: added the $PERSONAL_ACCOUNT includeIf to ~/.gitconfig"
fi
warn_if_missing "$PERSONAL_KEY"
