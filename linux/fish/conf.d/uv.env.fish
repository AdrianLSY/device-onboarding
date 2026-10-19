
# uv's installer writes env.fish only when ~/.local/bin is not on PATH yet, which
# it is under setup/app/.setup.sh, so the file may not exist.
test -f "$HOME/.local/share/../bin/env.fish"; and source "$HOME/.local/share/../bin/env.fish"
