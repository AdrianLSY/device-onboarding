# Git wrapper — auto-selects the correct GitHub account and SSH key for
# clone / submodule add / submodule init / submodule update, and stamps
# commit identity + SSH-signing config onto the resulting repos and any
# submodules they produce.
#
# Covers:
#   git clone <github URL> [<target>]
#   git submodule add <github URL> [<path>]
#   git submodule init  [<path>...]
#   git submodule update [--init [--recursive]] [<path>...]
#
# Per-repo config written:
#   core.sshCommand              = ssh -i <account-key> -o IdentitiesOnly=yes
#   user.name                    = Adrian Low
#   user.email                   = <account-email>
#   user.signingkey              = <account-signing-key.pub>
#   gpg.format                   = ssh
#   commit.gpgsign / tag.gpgsign = true
#   gpg.ssh.allowedSignersFile   = ~/.ssh/allowed_signers
#
# Only fish loads this wrapper (every fish that reads its config, interactive
# or not). Git run from anything else (Claude Code, bash scripts, systemd
# units, editors) takes its GitHub key from config that
# linux/setup/tweak/git-multi-account.sh writes: a `Host github.com` stanza in
# ~/.ssh/config defaulting to the Adrian-LSY key, and an includeIf in
# ~/.gitconfig that switches AdrianLSY/* remotes to the personal key. The
# wrapper still stamps identity and signing at clone time, and the per-repo
# core.sshCommand it writes wins over both. The tweak reads its keys from
# __git_ssh_key_for_account below, so keys are changed here only.

# ───────────────────────── per-account helpers ─────────────────────────

function __git_ssh_key_for_account -a account
    switch $account
        case Adrian-LSY
            echo "$HOME/.ssh/adrian_rooftop_ed25519"
        case AdrianLSY
            echo "$HOME/.ssh/sites_ad_p3_ed25519"
    end
end

function __git_email_for_account -a account
    switch $account
        case Adrian-LSY
            echo "adrian@rooftop.my"
        case AdrianLSY
            echo "adrianlow1998@gmail.com"
    end
end

function __git_signingkey_for_account -a account
    switch $account
        case Adrian-LSY
            echo "~/.ssh/adrian_rooftop_ed25519.pub"
        case AdrianLSY
            echo "~/.ssh/sites_ad_p3_ed25519.pub"
    end
end

# Echo the GitHub account that owns or has push access to $url. Falls back to
# AdrianLSY. Probing may switch gh auth temporarily; we save + restore.
function __git_resolve_account -a url
    set -l parts (string match -r -- 'github\.com[:/]([^/]+)/([^/ .]+)' $url)
    set -l owner $parts[2]
    set -l repo $parts[3]

    if test -z "$owner"; or test -z "$repo"
        echo AdrianLSY
        return
    end

    switch $owner
        case Adrian-LSY
            echo Adrian-LSY
            return
        case AdrianLSY
            echo AdrianLSY
            return
    end

    set -l saved (gh api user -q .login 2>/dev/null)
    set -l result AdrianLSY
    for try in Adrian-LSY AdrianLSY
        gh auth switch --user $try --hostname github.com 2>/dev/null
        set -l push (gh api "repos/$owner/$repo" -q '.permissions.push // false' 2>/dev/null)
        if test "$push" = "true"
            set result $try
            break
        end
    end
    if test -n "$saved"
        gh auth switch --user $saved --hostname github.com 2>/dev/null
    end
    echo $result
end

# Apply one account's identity + signing config to a single git dir.
function __git_apply_identity -a dir account
    set -l identity (__git_ssh_key_for_account $account)
    set -l email (__git_email_for_account $account)
    set -l signingkey (__git_signingkey_for_account $account)
    if test -z "$identity"
        return 1
    end
    command git -C "$dir" config core.sshCommand "ssh -i $identity -o IdentitiesOnly=yes"
    command git -C "$dir" config user.name "Adrian Low"
    command git -C "$dir" config user.email "$email"
    command git -C "$dir" config user.signingkey "$signingkey"
    command git -C "$dir" config gpg.format ssh
    command git -C "$dir" config commit.gpgsign true
    command git -C "$dir" config tag.gpgsign true
    command git -C "$dir" config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
end

# Apply identity to $top AND every initialized submodule under it (recursively),
# resolving each dir's account from its own origin URL. Skips non-github remotes.
function __git_configure_tree -a top
    set -l dirs $top
    for sm in (command git -C "$top" submodule foreach --recursive --quiet 'echo $toplevel/$sm_path' 2>/dev/null)
        set -a dirs $sm
    end
    for dir in $dirs
        if not test -d "$dir"
            continue
        end
        set -l url (command git -C "$dir" remote get-url origin 2>/dev/null)
        if test -z "$url"; or not string match -q "*github.com*" $url
            continue
        end
        set -l account (__git_resolve_account $url)
        __git_apply_identity "$dir" "$account"
    end
end

# ───────────────────────────── the wrapper ─────────────────────────────

function git --wraps git
    set -l sub $argv[1]
    set -l subsub ""
    if test (count $argv) -ge 2
        set subsub $argv[2]
    end

    # ── submodule add / init / update: run op, then configure tree ──
    if test "$sub" = submodule
        switch $subsub
            case add init update
                # Fetch the submodule(s) using the parent repo's account key so
                # the underlying clone/fetch succeeds. The env var propagates
                # into git's internal submodule operations.
                set -l top (command git rev-parse --show-toplevel 2>/dev/null)
                if test -n "$top"
                    set -l parent_url (command git -C "$top" remote get-url origin 2>/dev/null)
                    if test -n "$parent_url"; and string match -q "*github.com*" $parent_url
                        set -l parent_account (__git_resolve_account $parent_url)
                        set -l parent_key (__git_ssh_key_for_account $parent_account)
                        if test -n "$parent_key"
                            set -lx GIT_SSH_COMMAND "ssh -i $parent_key -o IdentitiesOnly=yes"
                        end
                    end
                end

                command git $argv
                set -l ret $status
                set -e GIT_SSH_COMMAND

                if test $ret -eq 0; and test -n "$top"
                    __git_configure_tree "$top"
                    echo "Auto-configured submodules under $top"
                end
                return $ret
        end
    end

    # ── anything else non-clone: passthrough ──
    if test "$sub" != clone
        command git $argv
        return
    end

    # ── clone ──
    set -l url ""
    set -l rest $argv[2..-1]
    for arg in $rest
        if string match -q -- "-*" $arg
            continue
        end
        if string match -q "*github.com*" $arg
            set url $arg
            break
        end
    end

    if test -z "$url"
        command git $argv
        return
    end

    set -l parts (string match -r -- 'github\.com[:/]([^/]+)/([^/ .]+)' $url)
    set -l owner $parts[2]
    set -l repo $parts[3]
    if test -z "$owner"; or test -z "$repo"
        command git $argv
        return
    end

    set -l account (__git_resolve_account $url)
    set -l identity (__git_ssh_key_for_account $account)

    gh auth switch --user $account --hostname github.com 2>/dev/null

    set -lx GIT_SSH_COMMAND "ssh -i $identity -o IdentitiesOnly=yes"
    command git $argv
    set -l ret $status
    set -e GIT_SSH_COMMAND

    if test $ret -eq 0
        # Determine clone target directory
        set -l target ""
        set -l found_url 0
        for arg in $rest
            if string match -q -- "-*" $arg
                continue
            end
            if test $found_url -eq 1
                set target $arg
                break
            end
            if test "$arg" = "$url"
                set found_url 1
            end
        end
        if test -z "$target"
            set target $repo
        end

        if test -d "$target"
            __git_configure_tree "$target"
            echo "Auto-configured for $account ("(__git_email_for_account $account)")"
        end
    end

    return $ret
end
