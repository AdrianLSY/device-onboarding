#!/bin/bash
set -e

sudo pacman -S --noconfirm github-cli

# Global identity and signing: the work account (Adrian-LSY). Repos whose remote
# is the personal AdrianLSY account get the personal email and signing key from
# the includeIf that tweak/git-multi-account.sh adds after these lines. The
# values match the fish git wrapper's (fish/conf.d/git-multi-account.fish).
git config --global user.email "adrian@rooftop.my"
git config --global user.name "Adrian Low"

# SSH signing configuration (for verified commits). git expands the ~ itself.
git config --global gpg.format ssh
# shellcheck disable=SC2088
git config --global user.signingkey "~/.ssh/adrian_rooftop_ed25519.pub"
git config --global commit.gpgsign true

# Allowed signers for both accounts, at the path the git wrapper stamps, so
# `git log --show-signature` verifies commits signed with either key. Idempotent:
# a principal already listed is left alone, and a key not on this machine yet is
# skipped until a re-run.
ALLOWED_SIGNERS_FILE="$HOME/.ssh/allowed_signers"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
while read -r principal key; do
    if grep -qF "$principal " "$ALLOWED_SIGNERS_FILE" 2>/dev/null; then
        continue
    fi
    if [ ! -f "$HOME/.ssh/$key.pub" ]; then
        echo "allowed_signers: ~/.ssh/$key.pub is not on this machine yet; skipped $principal"
        continue
    fi
    (umask 077 && echo "$principal $(cut -d' ' -f1,2 "$HOME/.ssh/$key.pub")" >>"$ALLOWED_SIGNERS_FILE")
done <<'EOF'
adrian@rooftop.my adrian_rooftop_ed25519
adrianlow1998@gmail.com sites_ad_p3_ed25519
EOF
git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS_FILE"
