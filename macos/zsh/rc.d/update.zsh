update() {
  brew update && brew upgrade && brew cleanup
  zinit update --all
  # cf ships only on npm, so brew never upgrades it
  # (macos/setup/tweak/cloudflare-cli.sh installs it).
  if command -v npm >/dev/null && npm ls --global cf >/dev/null 2>&1; then
    npm install --global --no-audit --no-fund cf@latest
  fi
}
