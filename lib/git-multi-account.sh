# shellcheck shell=bash
# lib/git-multi-account.sh: GitHub SSH for git that runs outside the shell that
# loads the tier's `git` wrapper (macos/zsh/rc.d/git-multi-account.zsh in an
# interactive zsh, linux/fish/conf.d/git-multi-account.fish in fish): Claude
# Code, scripts, launchd or systemd jobs, editors. Without this nothing offers
# GitHub a key there, and every clone and push fails with "Permission denied
# (publickey)".
#
# SOURCEABLE library, like lib/link.sh: it defines functions and constants only.
# Each tier's setup/tweak/git-multi-account.sh sources it and calls
#     git_multi_account <zsh|fish> <wrapper>
# under `set -e`, so a failed step stops the tweak.
#
# Two pieces; once both are in place, a second run changes nothing:
#   1. ~/.ssh/config gets a `Host github.com ssh.github.com` stanza that defaults
#      to the work account's key. It sits OUTSIDE ssh-keypick's managed block
#      (macOS), so `ssh-keypick install` keeps it. An existing github.com Host or
#      Match host stanza is the user's and is never rewritten.
#   2. The global git config gets an includeIf on remotes of the personal
#      account. The included ~/.config/git/github-personal.gitconfig sets
#      core.sshCommand to `ssh -i <personal key>`; -i is offered ahead of the
#      IdentityFile above, so GitHub sees the personal account for those repos.
#      (`hasconfig:` needs git 2.36 or later.)
#
# Each file is backed up before it is first changed. At clone time the
# interactive wrapper still stamps each repo's own core.sshCommand, identity and
# signing config, which win over both pieces. Each account's key is read from
# the wrapper's __git_ssh_key_for_account, the one place it is set.

# Backups reuse lib/link.sh's _link_backup_path (non-colliding <file>.bak.<timestamp>).
# shellcheck source=lib/link.sh
. "$(dirname "${BASH_SOURCE[0]}")/link.sh"

GMA_WORK_ACCOUNT=Adrian-LSY      # default for github.com
GMA_PERSONAL_ACCOUNT=AdrianLSY   # selected by remote URL

GMA_KEYPICK_BEGIN="# >>> keypick managed block (do not edit between markers) >>>"
GMA_KEYPICK_END="# <<< keypick managed block <<<"

# shellcheck disable=SC2088  # git expands the ~ itself; keep it literal
GMA_PERSONAL_GITCONFIG_REF='~/.config/git/github-personal.gitconfig'
GMA_INCLUDE_KEY="includeIf.hasconfig:remote.*.url:git@github.com:$GMA_PERSONAL_ACCOUNT/**.path"

# _gma_wrapper_key <zsh|fish> <wrapper> <account>
# Echo the account's private key path as the wrapper defines it. Neither shell
# reads its rc files here (zsh -f, fish --no-config), so only the wrapper's
# function definitions load.
_gma_wrapper_key() {
    # shellcheck disable=SC2016  # the inner shell expands $1 and $argv
    case "$1" in
        zsh)  zsh -fc 'source "$1" && __git_ssh_key_for_account "$2"' zsh "$2" "$3" ;;
        fish) fish --no-config -c 'source $argv[1]; and __git_ssh_key_for_account $argv[2]' "$2" "$3" ;;
        *)    echo "git-multi-account: no key reader for shell '$1'" >&2; return 1 ;;
    esac
}

# _gma_key_for <zsh|fish> <wrapper> <account>
# Echo the account's key, ~-abbreviated. Fails if the wrapper names none.
_gma_key_for() {
    local key
    key="$(_gma_wrapper_key "$1" "$2" "$3")"
    if [ -z "$key" ]; then
        echo "git-multi-account: no key for $3 in $2" >&2
        return 1
    fi
    case "$key" in
        "$HOME"/*) printf '%s\n' "~${key#"$HOME"}" ;;
        *)         printf '%s\n' "$key" ;;
    esac
}

_gma_expand_tilde() {
    case "$1" in
        "~"/*) printf '%s\n' "$HOME/${1#"~/"}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# Copy <file> to a non-colliding backup before changing it.
_gma_backup() {
    local bak
    bak="$(_link_backup_path "$1")"
    cp -p "$1" "$bak"
    echo "git-multi-account: backed up $1 -> $bak"
}

_gma_warn_if_missing() {
    [ -f "$(_gma_expand_tilde "$1")" ] ||
        echo "git-multi-account: $1 is not on this machine yet; add it to ~/.ssh and this config starts working"
}

# _gma_has_github_stanza <ssh config>
# True if a Host (or Match host) line outside the keypick managed block already
# names github.com.
_gma_has_github_stanza() {
    [ -f "$1" ] || return 1
    awk -v b="$GMA_KEYPICK_BEGIN" -v e="$GMA_KEYPICK_END" '
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
    ' "$1"
}

# ── 1. ~/.ssh/config: default github.com to the work key ──
# _gma_ssh_config <shell> <work key>
_gma_ssh_config() {
    local ssh_config stanza tmp
    ssh_config="$HOME/.ssh/config"
    stanza="# GitHub: two accounts share this host, and the git wrapper that picks one per
# repo only loads in $1, so ssh would offer no key to git run from anything
# else. Default to the work account ($GMA_WORK_ACCOUNT); $GMA_PERSONAL_ACCOUNT/*
# repos switch to the personal key through an includeIf in the global git
# config. Written by device-onboarding's git-multi-account tweak, outside any
# keypick managed block so \`ssh-keypick install\` keeps it.
Host github.com ssh.github.com
    IdentityFile $2
    IdentitiesOnly yes"

    if _gma_has_github_stanza "$ssh_config"; then
        echo "git-multi-account: $ssh_config already has a github.com stanza; left alone"
        return 0
    fi
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    tmp="$(mktemp "$ssh_config.XXXXXX")"
    if [ -f "$ssh_config" ]; then
        _gma_backup "$ssh_config"
        if grep -qxF "$GMA_KEYPICK_END" "$ssh_config"; then
            # Directly after the managed block, ahead of any `Host *` defaults.
            STANZA="$stanza" awk -v e="$GMA_KEYPICK_END" '
                { print }
                $0==e && !done { print ""; print ENVIRON["STANZA"]; done=1 }
            ' "$ssh_config" >"$tmp"
        else
            { printf '%s\n\n' "$stanza"; cat "$ssh_config"; } >"$tmp"
        fi
    else
        printf '%s\n' "$stanza" >"$tmp"
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$ssh_config"
    echo "git-multi-account: added the github.com stanza to $ssh_config"
}

# The file `git config --global` writes to: $GIT_CONFIG_GLOBAL if set, else
# ~/.gitconfig, unless only the XDG ~/.config/git/config exists.
_gma_global_gitconfig() {
    local xdg
    xdg="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
    if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
        printf '%s\n' "$GIT_CONFIG_GLOBAL"
    elif [ ! -f "$HOME/.gitconfig" ] && [ -f "$xdg" ]; then
        printf '%s\n' "$xdg"
    else
        printf '%s\n' "$HOME/.gitconfig"
    fi
}

# The include counts as present whether it names the file as ~/… or by full path.
_gma_include_present() {
    local path
    while IFS= read -r path; do
        [ "$(_gma_expand_tilde "$path")" = "$1" ] && return 0
    done < <(git config --global --get-all "$GMA_INCLUDE_KEY" 2>/dev/null)
    return 1
}

# ── 2. global git config: personal key for the personal account's remotes ──
# _gma_git_config <personal key>
_gma_git_config() {
    local personal_gitconfig ssh_command global
    personal_gitconfig="$(_gma_expand_tilde "$GMA_PERSONAL_GITCONFIG_REF")"
    ssh_command="ssh -i $1 -o IdentitiesOnly=yes"

    if [ "$(git config --file "$personal_gitconfig" --get core.sshCommand 2>/dev/null)" = "$ssh_command" ]; then
        echo "git-multi-account: $personal_gitconfig already set; left alone"
    else
        if [ -f "$personal_gitconfig" ]; then
            _gma_backup "$personal_gitconfig"
        else
            mkdir -p "$(dirname "$personal_gitconfig")"
            cat >"$personal_gitconfig" <<EOF
# Included by the global git config for repos whose remote is the personal
# $GMA_PERSONAL_ACCOUNT GitHub account. ~/.ssh/config defaults github.com to the work
# key ($GMA_WORK_ACCOUNT); -i puts the personal key ahead of it, so GitHub
# authenticates these repos as $GMA_PERSONAL_ACCOUNT. Written by device-onboarding's
# git-multi-account tweak.
EOF
        fi
        git config --file "$personal_gitconfig" core.sshCommand "$ssh_command"
        echo "git-multi-account: set core.sshCommand in $personal_gitconfig"
    fi

    global="$(_gma_global_gitconfig)"
    if _gma_include_present "$personal_gitconfig"; then
        echo "git-multi-account: the global git config already includes $GMA_PERSONAL_GITCONFIG_REF; left alone"
    else
        if [ -f "$global" ]; then
            _gma_backup "$global"
        fi
        git config --global --add "$GMA_INCLUDE_KEY" "$GMA_PERSONAL_GITCONFIG_REF"
        echo "git-multi-account: added the $GMA_PERSONAL_ACCOUNT includeIf to $global"
    fi
}

# git_multi_account <zsh|fish> <wrapper>
# Read both keys from <wrapper> with <shell>, then write the two pieces above.
git_multi_account() {
    local shell wrapper work_key personal_key
    shell="$1"
    wrapper="$2"
    if ! command -v "$shell" >/dev/null 2>&1; then
        echo "git-multi-account: $shell is not installed, so the keys in $wrapper cannot be read" >&2
        return 1
    fi
    work_key="$(_gma_key_for "$shell" "$wrapper" "$GMA_WORK_ACCOUNT")"
    personal_key="$(_gma_key_for "$shell" "$wrapper" "$GMA_PERSONAL_ACCOUNT")"

    _gma_ssh_config "$shell" "$work_key"
    _gma_warn_if_missing "$work_key"
    _gma_git_config "$personal_key"
    _gma_warn_if_missing "$personal_key"
}
