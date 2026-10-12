# shellcheck shell=bash
# lib/git-multi-account.sh: GitHub SSH, and the personal account's commit
# identity and signing, for git that runs outside the shell that loads the
# tier's `git` wrapper (macos/zsh/rc.d/git-multi-account.zsh in an interactive
# zsh, linux/fish/conf.d/git-multi-account.fish in fish): Claude Code, scripts,
# launchd or systemd jobs, editors. Without this nothing offers GitHub a key
# there, every clone and push fails with "Permission denied (publickey)", a
# personal repo the wrapper never stamped commits as the work identity, and an
# HTTPS push authenticates as whichever account gh has active.
#
# SOURCEABLE library, like lib/link.sh: it defines functions and constants only.
# Each tier's setup/tweak/git-multi-account.sh sources it and calls
#     git_multi_account <zsh|fish> <wrapper>
# under `set -e`, so a failed step stops the tweak.
#
# Three pieces; once all are in place, a second run changes nothing:
#   1. ~/.ssh/config gets a `Host github.com ssh.github.com` stanza that defaults
#      to the work account's key. It sits OUTSIDE ssh-keypick's managed block
#      (macOS), so `ssh-keypick install` keeps it. An existing github.com Host or
#      Match host stanza is the user's and is never rewritten.
#   2. The global git config gets an includeIf for each URL form a clone of the
#      personal account can have: the scp-like git@github.com: form the wrapper
#      clones with, and the https:// and ssh:// URLs that `gh repo clone` and
#      other tools write. All three include
#      ~/.config/git/github-personal.gitconfig, which sets core.sshCommand to
#      `ssh -i <personal key>`; -i is offered ahead of the IdentityFile above,
#      so GitHub sees the personal account for those repos. git runs ssh only
#      for an ssh transport, so for an https remote the setting does nothing.
#      The file also sets the personal user.email, user.signingkey, gpg.format
#      ssh and commit.gpgsign, so their commits are authored and signed as that
#      account. The includes sit after the global [user] settings, and git
#      reads an included file at the include's position, so its values win.
#      (`hasconfig:` needs git 2.36 or later.)
#   3. The global git config gets two credential sections for GitHub over
#      HTTPS, so a push authenticates as the account that owns the repo rather
#      than the one gh has active, which the wrapper switches on every clone.
#      Like the ssh stanza, the work account is the default and the personal
#      account's own URLs switch to it. Each section's helper asks gh for that
#      account's token by name (`gh auth token --user`). See
#      _gma_https_credentials for why they must come after gh's own section.
#
# Each file is backed up once per run, before it is first changed. At clone
# time the interactive wrapper still stamps each repo's own core.sshCommand,
# identity and signing config, which win over the first two pieces. Each key,
# email and signing key is read from the wrapper's per-account helpers
# (__git_ssh_key_for_account, __git_email_for_account,
# __git_signingkey_for_account), the one place it is set.

# Backups reuse lib/link.sh's _link_backup_path (non-colliding <file>.bak.<timestamp>).
# shellcheck source=lib/link.sh
. "$(dirname "${BASH_SOURCE[0]}")/link.sh"

GMA_WORK_ACCOUNT=Adrian-LSY      # default for github.com
GMA_PERSONAL_ACCOUNT=AdrianLSY   # selected by remote URL

GMA_KEYPICK_BEGIN="# >>> keypick managed block (do not edit between markers) >>>"
GMA_KEYPICK_END="# <<< keypick managed block <<<"

# shellcheck disable=SC2088  # git expands the ~ itself; keep it literal
GMA_PERSONAL_GITCONFIG_REF='~/.config/git/github-personal.gitconfig'
# The personal account's remote URLs, as hasconfig: globs. They match
# case-sensitively, `*` stops at a slash and `/**` spans any number of them.
GMA_PERSONAL_URL_GLOBS=(
    "git@github.com:$GMA_PERSONAL_ACCOUNT/**"
    "https://github.com/$GMA_PERSONAL_ACCOUNT/**"
    "ssh://git@github.com/$GMA_PERSONAL_ACCOUNT/**"
)

# _gma_include_key <url glob>
_gma_include_key() {
    printf '%s\n' "includeIf.hasconfig:remote.*.url:$1.path"
}

# The credential sections' URLs. git matches a section's path against the
# request's at a slash boundary and case-sensitively. The default's trailing
# slash matches the same URLs as gh's [credential "https://github.com"] but
# keeps it a separate section.
GMA_CRED_DEFAULT_URL='https://github.com/'
GMA_CRED_PERSONAL_URL="https://github.com/$GMA_PERSONAL_ACCOUNT"
# Keys of those two sections, and keys elsewhere that would override them if
# they came later in the file.
GMA_CRED_OURS_RE="^credential\\.https://github\\.com/($GMA_PERSONAL_ACCOUNT)?\\."
GMA_CRED_FOREIGN_RE='^credential\.(https://github\.com\.)?(helper|username)$'

# _gma_wrapper_call <zsh|fish> <wrapper> <helper> <account>
# Echo what the wrapper's per-account <helper> prints for <account>. Neither
# shell reads its rc files here (zsh -f, fish --no-config), so only the
# wrapper's function definitions load.
_gma_wrapper_call() {
    # shellcheck disable=SC2016  # the inner shell expands $1 and $argv
    case "$1" in
        zsh)  zsh -fc 'source "$1" && "$2" "$3"' zsh "$2" "$3" "$4" ;;
        fish) fish --no-config -c 'source $argv[1]; and $argv[2] $argv[3]' "$2" "$3" "$4" ;;
        *)    echo "git-multi-account: no wrapper reader for shell '$1'" >&2; return 1 ;;
    esac
}

# _gma_value_for <zsh|fish> <wrapper> <helper> <account>
# Echo the helper's value for the account, with a leading $HOME abbreviated to
# ~. Fails if the wrapper prints nothing.
_gma_value_for() {
    local value
    value="$(_gma_wrapper_call "$1" "$2" "$3" "$4")"
    if [ -z "$value" ]; then
        echo "git-multi-account: $3 prints nothing for $4 in $2" >&2
        return 1
    fi
    case "$value" in
        "$HOME"/*) printf '%s\n' "~${value#"$HOME"}" ;;
        *)         printf '%s\n' "$value" ;;
    esac
}

_gma_expand_tilde() {
    case "$1" in
        "~"/*) printf '%s\n' "$HOME/${1#"~/"}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# Copy <file> to a non-colliding backup before changing it, once per run: the
# global git config can be changed by two pieces, and the backup worth keeping
# is the one from before the first.
_GMA_BACKED_UP=()
_gma_backup() {
    local bak f
    for f in ${_GMA_BACKED_UP[@]+"${_GMA_BACKED_UP[@]}"}; do
        [ "$f" = "$1" ] && return 0
    done
    bak="$(_link_backup_path "$1")"
    cp -p "$1" "$bak"
    _GMA_BACKED_UP+=("$1")
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

# _gma_include_present <url glob> <file>
# True if the global config includes <file> for remotes matching <url glob>,
# whether it names the file as ~/… or by full path.
_gma_include_present() {
    local path
    while IFS= read -r path; do
        [ "$(_gma_expand_tilde "$path")" = "$2" ] && return 0
    done < <(git config --global --get-all "$(_gma_include_key "$1")" 2>/dev/null)
    return 1
}

# ── 2. global git config: the personal account's key, identity and signing ──
# _gma_git_config <personal key> <personal email> <personal signing key>
_gma_git_config() {
    local personal_gitconfig global glob i
    local -a settings stale missing
    personal_gitconfig="$(_gma_expand_tilde "$GMA_PERSONAL_GITCONFIG_REF")"
    # <key> <value> pairs for the included file.
    settings=(
        core.sshCommand "ssh -i $1 -o IdentitiesOnly=yes"
        user.email      "$2"
        user.signingkey "$3"
        gpg.format      ssh
        commit.gpgsign  true
    )

    # The index of each key whose value is missing or different.
    stale=()
    for ((i = 0; i < ${#settings[@]}; i += 2)); do
        [ "$(git config --file "$personal_gitconfig" --get "${settings[i]}" 2>/dev/null)" = "${settings[i+1]}" ] ||
            stale+=("$i")
    done

    if [ ${#stale[@]} -eq 0 ]; then
        echo "git-multi-account: $personal_gitconfig already set; left alone"
    else
        if [ -f "$personal_gitconfig" ]; then
            _gma_backup "$personal_gitconfig"
        else
            mkdir -p "$(dirname "$personal_gitconfig")"
            cat >"$personal_gitconfig" <<EOF
# Included by the global git config for repos whose remote is the personal
# $GMA_PERSONAL_ACCOUNT GitHub account (git@github.com:, https:// or ssh://), so they
# commit and sign as that account and, over ssh, authenticate as it. The global
# config defaults to the work account ($GMA_WORK_ACCOUNT), and -i puts the personal
# key ahead of the work key that ~/.ssh/config offers; git never runs ssh for an
# https:// remote, so there core.sshCommand does nothing. A repo the git wrapper
# stamped at clone time has its own copy of these settings, which wins. Written
# by device-onboarding's git-multi-account tweak from the values in the tier's
# git wrapper.
EOF
        fi
        for i in "${stale[@]}"; do
            git config --file "$personal_gitconfig" --replace-all "${settings[i]}" "${settings[i+1]}"
            echo "git-multi-account: set ${settings[i]} in $personal_gitconfig"
        done
    fi

    # Each URL form is checked on its own, so a config with only some of the
    # includes gets just the rest, behind a single backup.
    global="$(_gma_global_gitconfig)"
    missing=()
    for glob in "${GMA_PERSONAL_URL_GLOBS[@]}"; do
        _gma_include_present "$glob" "$personal_gitconfig" || missing+=("$glob")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        echo "git-multi-account: the global git config already includes $GMA_PERSONAL_GITCONFIG_REF for every $GMA_PERSONAL_ACCOUNT URL form; left alone"
    else
        if [ -f "$global" ]; then
            _gma_backup "$global"
        fi
        for glob in "${missing[@]}"; do
            git config --global --add "$(_gma_include_key "$glob")" "$GMA_PERSONAL_GITCONFIG_REF"
            echo "git-multi-account: added the includeIf for $glob remotes to $global"
        done
    fi
}

# _gma_cred_helper <gh> <account>
# A credential helper that answers `get` with <account>'s token from gh, whatever
# account gh has active, and answers nothing when gh holds no token for it.
_gma_cred_helper() {
    printf '%s\n' "!f() { [ \"\$1\" = get ] || return 0; t=\$('$1' auth token --hostname github.com --user $2 2>/dev/null) || return 0; echo username=$2; echo \"password=\$t\"; }; f"
}

# ── 3. global git config: GitHub over HTTPS as the account that owns the repo ──
# git collects every credential section that matches the URL, in file order, and
# an empty helper clears the list, so the last match decides. Ours therefore
# have to come after gh's [credential "https://github.com"] section and after
# any URL-less [credential]. `gh auth setup-git` rewrites its section in place,
# but on a machine without one it appends a new section, after ours. Each of our
# sections also names its username, so gh's helper then answers only for that
# account, and a push fails rather than authenticating as the wrong one. The
# next run moves ours back to the end.
_gma_https_credentials() {
    local gh global tmp want have order first_ours last_foreign account
    gh="$(command -v gh || true)"
    if [ -z "$gh" ]; then
        echo "git-multi-account: gh is not installed, so GitHub over HTTPS keeps git's own credential helpers"
        return 0
    fi
    global="$(_gma_global_gitconfig)"

    # The two sections as git writes them, with a note under the first header.
    tmp="$(mktemp)"
    git config --file "$tmp" --add "credential.$GMA_CRED_DEFAULT_URL.helper" ''
    git config --file "$tmp" --add "credential.$GMA_CRED_DEFAULT_URL.helper" "$(_gma_cred_helper "$gh" "$GMA_WORK_ACCOUNT")"
    git config --file "$tmp" "credential.$GMA_CRED_DEFAULT_URL.username" "$GMA_WORK_ACCOUNT"
    git config --file "$tmp" --add "credential.$GMA_CRED_PERSONAL_URL.helper" ''
    git config --file "$tmp" --add "credential.$GMA_CRED_PERSONAL_URL.helper" "$(_gma_cred_helper "$gh" "$GMA_PERSONAL_ACCOUNT")"
    git config --file "$tmp" "credential.$GMA_CRED_PERSONAL_URL.username" "$GMA_PERSONAL_ACCOUNT"
    want="$(git config --file "$tmp" --get-regexp "$GMA_CRED_OURS_RE")"
    have="$(git config --global --get-regexp "$GMA_CRED_OURS_RE" 2>/dev/null || true)"

    # In file order: the line of our first key and of the last key that could override it.
    order="$(git config --global --list --name-only 2>/dev/null || true)"
    first_ours="$(printf '%s\n' "$order" | grep -n -E "$GMA_CRED_OURS_RE" | head -1 | cut -d: -f1)"
    last_foreign="$(printf '%s\n' "$order" | grep -n -E "$GMA_CRED_FOREIGN_RE" | tail -1 | cut -d: -f1)"

    if [ "$have" = "$want" ] && { [ -z "$last_foreign" ] || [ "$first_ours" -gt "$last_foreign" ]; }; then
        echo "git-multi-account: the global git config already sends GitHub over HTTPS as the repo's account; left alone"
    else
        if [ -f "$global" ]; then
            _gma_backup "$global"
        fi
        git config --global --remove-section "credential.$GMA_CRED_DEFAULT_URL" 2>/dev/null || true
        git config --global --remove-section "credential.$GMA_CRED_PERSONAL_URL" 2>/dev/null || true
        if [ -s "$global" ] && [ -n "$(tail -c1 "$global")" ]; then
            echo >>"$global"
        fi
        # Appended as text rather than with `git config`, which would add to an
        # existing section and cannot write the note.
        awk -v h="[credential \"$GMA_CRED_DEFAULT_URL\"]" -v w="$GMA_WORK_ACCOUNT" -v p="$GMA_PERSONAL_ACCOUNT" '
            { print }
            $0 == h {
                print "\t# Written by device-onboarding'"'"'s git-multi-account tweak: GitHub"
                print "\t# over HTTPS as the account that owns the repo, not the one gh has"
                print "\t# active. " w " by default, " p " for its own repos below. The"
                print "\t# trailing slash keeps this apart from gh'"'"'s section, which must"
                print "\t# come first."
            }
        ' "$tmp" >>"$global"
        echo "git-multi-account: added the GitHub HTTPS credential sections to $global"
    fi
    rm -f "$tmp"

    for account in "$GMA_WORK_ACCOUNT" "$GMA_PERSONAL_ACCOUNT"; do
        "$gh" auth token --hostname github.com --user "$account" >/dev/null 2>&1 ||
            echo "git-multi-account: gh holds no github.com token for $account yet; once \`gh auth login\` adds it, HTTPS works for its repos"
    done
}

# git_multi_account <zsh|fish> <wrapper>
# Read both keys, and the personal email and signing key, from <wrapper> with
# <shell>, then write the three pieces above.
git_multi_account() {
    local shell wrapper work_key personal_key personal_email personal_signingkey
    shell="$1"
    wrapper="$2"
    if ! command -v "$shell" >/dev/null 2>&1; then
        echo "git-multi-account: $shell is not installed, so the values in $wrapper cannot be read" >&2
        return 1
    fi
    work_key="$(_gma_value_for "$shell" "$wrapper" __git_ssh_key_for_account "$GMA_WORK_ACCOUNT")"
    personal_key="$(_gma_value_for "$shell" "$wrapper" __git_ssh_key_for_account "$GMA_PERSONAL_ACCOUNT")"
    personal_email="$(_gma_value_for "$shell" "$wrapper" __git_email_for_account "$GMA_PERSONAL_ACCOUNT")"
    personal_signingkey="$(_gma_value_for "$shell" "$wrapper" __git_signingkey_for_account "$GMA_PERSONAL_ACCOUNT")"

    _gma_ssh_config "$shell" "$work_key"
    _gma_warn_if_missing "$work_key"
    _gma_git_config "$personal_key" "$personal_email" "$personal_signingkey"
    _gma_warn_if_missing "$personal_key"
    _gma_warn_if_missing "$personal_signingkey"
    _gma_https_credentials
}
