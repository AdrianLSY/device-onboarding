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
# Only an interactive zsh loads this wrapper. Git run anywhere else (Claude
# Code, scripts, launchd, editors) takes its GitHub key from config that
# macos/setup/tweak/git-multi-account.sh writes: a `Host github.com` stanza in
# ~/.ssh/config defaulting to the Adrian-LSY key, and an includeIf in
# ~/.gitconfig that gives AdrianLSY/* remotes the personal key, email and
# commit signing. The wrapper still stamps identity and signing at clone time,
# and the per-repo config it writes wins over both. The tweak reads its values
# from the per-account helpers below, so keys and emails are changed here only.

# ───────────────────────── per-account helpers ─────────────────────────

__git_ssh_key_for_account() {
  case "$1" in
    Adrian-LSY) echo "$HOME/.ssh/adrian_rooftop_ed25519" ;;
    AdrianLSY)  echo "$HOME/.ssh/sites_ad_p3_ed25519" ;;
  esac
}

__git_email_for_account() {
  case "$1" in
    Adrian-LSY) echo "adrian@rooftop.my" ;;
    AdrianLSY)  echo "adrianlow1998@gmail.com" ;;
  esac
}

__git_signingkey_for_account() {
  case "$1" in
    Adrian-LSY) echo "~/.ssh/adrian_rooftop_ed25519.pub" ;;
    AdrianLSY)  echo "~/.ssh/sites_ad_p3_ed25519.pub" ;;
  esac
}

# Echo the GitHub account that owns or has push access to $url. Falls back to
# AdrianLSY. Probing may switch gh auth temporarily; we save + restore.
__git_resolve_account() {
  local url="$1"
  local owner repo
  owner=$(echo "$url" | sed -nE 's|.*github\.com[:/]([^/]+)/.*|\1|p' | head -1)
  repo=$(echo "$url" | sed -nE 's|.*github\.com[:/][^/]+/([^/ .]+).*|\1|p' | head -1)

  if [[ -z "$owner" || -z "$repo" ]]; then
    echo AdrianLSY
    return
  fi

  case "$owner" in
    Adrian-LSY) echo Adrian-LSY; return ;;
    AdrianLSY)  echo AdrianLSY;  return ;;
  esac

  local saved result try push
  saved=$(gh api user -q .login 2>/dev/null)
  result=AdrianLSY
  for try in Adrian-LSY AdrianLSY; do
    gh auth switch --user "$try" --hostname github.com 2>/dev/null
    push=$(gh api "repos/$owner/$repo" -q '.permissions.push // false' 2>/dev/null)
    if [[ "$push" == "true" ]]; then
      result="$try"
      break
    fi
  done
  if [[ -n "$saved" ]]; then
    gh auth switch --user "$saved" --hostname github.com 2>/dev/null
  fi
  echo "$result"
}

# Apply one account's identity + signing config to a single git dir.
__git_apply_identity() {
  local dir="$1" account="$2"
  local identity email signingkey
  identity=$(__git_ssh_key_for_account "$account")
  email=$(__git_email_for_account "$account")
  signingkey=$(__git_signingkey_for_account "$account")
  [[ -z "$identity" ]] && return 1
  command git -C "$dir" config core.sshCommand "ssh -i $identity -o IdentitiesOnly=yes"
  command git -C "$dir" config user.name "Adrian Low"
  command git -C "$dir" config user.email "$email"
  command git -C "$dir" config user.signingkey "$signingkey"
  command git -C "$dir" config gpg.format ssh
  command git -C "$dir" config commit.gpgsign true
  command git -C "$dir" config tag.gpgsign true
  command git -C "$dir" config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
}

# Apply identity to $top AND every initialized submodule under it (recursively),
# resolving each dir's account from its own origin URL. Skips non-github remotes.
__git_configure_tree() {
  local top="$1"
  local -a dirs
  dirs=("$top")
  local sm
  while IFS= read -r sm; do
    [[ -n "$sm" ]] && dirs+=("$sm")
  done < <(command git -C "$top" submodule foreach --recursive --quiet 'echo $toplevel/$sm_path' 2>/dev/null)

  local dir url account
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    url=$(command git -C "$dir" remote get-url origin 2>/dev/null)
    [[ -z "$url" || "$url" != *github.com* ]] && continue
    account=$(__git_resolve_account "$url")
    __git_apply_identity "$dir" "$account"
  done
}

# ───────────────────────────── the wrapper ─────────────────────────────

git() {
  local sub="$1"
  local subsub=""
  (( $# >= 2 )) && subsub="$2"

  # ── submodule add / init / update: run op, then configure tree ──
  if [[ "$sub" == "submodule" ]]; then
    case "$subsub" in
      add|init|update)
        local top parent_url parent_account parent_key ret
        top=$(command git rev-parse --show-toplevel 2>/dev/null)
        parent_key=""
        if [[ -n "$top" ]]; then
          parent_url=$(command git -C "$top" remote get-url origin 2>/dev/null)
          if [[ -n "$parent_url" && "$parent_url" == *github.com* ]]; then
            parent_account=$(__git_resolve_account "$parent_url")
            parent_key=$(__git_ssh_key_for_account "$parent_account")
          fi
        fi

        if [[ -n "$parent_key" ]]; then
          GIT_SSH_COMMAND="ssh -i $parent_key -o IdentitiesOnly=yes" command git "$@"
          ret=$?
        else
          command git "$@"
          ret=$?
        fi

        if [[ $ret -eq 0 && -n "$top" ]]; then
          __git_configure_tree "$top"
          echo "Auto-configured submodules under $top"
        fi
        return $ret
        ;;
    esac
  fi

  # ── anything else non-clone: passthrough ──
  if [[ "$sub" != "clone" ]]; then
    command git "$@"
    return
  fi

  # ── clone ──
  local url=""
  local -a args
  args=("$@")
  local arg
  for arg in "${args[@]:1}"; do
    [[ "$arg" == -* ]] && continue
    if [[ "$arg" == *github.com* ]]; then
      url="$arg"
      break
    fi
  done

  if [[ -z "$url" ]]; then
    command git "$@"
    return
  fi

  local owner repo
  owner=$(echo "$url" | sed -nE 's|.*github\.com[:/]([^/]+)/.*|\1|p' | head -1)
  repo=$(echo "$url" | sed -nE 's|.*github\.com[:/][^/]+/([^/ .]+).*|\1|p' | head -1)

  if [[ -z "$owner" || -z "$repo" ]]; then
    command git "$@"
    return
  fi

  local account identity
  account=$(__git_resolve_account "$url")
  identity=$(__git_ssh_key_for_account "$account")

  gh auth switch --user "$account" --hostname github.com 2>/dev/null

  GIT_SSH_COMMAND="ssh -i $identity -o IdentitiesOnly=yes" command git "$@"
  local ret=$?

  if [[ $ret -eq 0 ]]; then
    # Determine clone target directory
    local target="" found_url=0
    for arg in "${args[@]:1}"; do
      [[ "$arg" == -* ]] && continue
      if (( found_url )); then
        target="$arg"
        break
      fi
      [[ "$arg" == "$url" ]] && found_url=1
    done
    [[ -z "$target" ]] && target="$repo"

    if [[ -d "$target" ]]; then
      __git_configure_tree "$target"
      echo "Auto-configured for $account ($(__git_email_for_account "$account"))"
    fi
  fi

  return $ret
}
