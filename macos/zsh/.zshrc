# Zinit
export ZINIT_HOME="$HOME/.local/share/zinit/zinit.git"
source $ZINIT_HOME/zinit.zsh

# Starship prompt
eval "$(starship init zsh)"
export STARSHIP_LOG=error

# Async plugins
zinit ice wait lucid
zinit light zsh-users/zsh-autosuggestions

zinit ice wait lucid
zinit light zsh-users/zsh-syntax-highlighting

# History
HISTFILE="$ZDOTDIR/.zsh_history"
HISTSIZE=2000
SAVEHIST=2000
setopt HIST_IGNORE_ALL_DUPS
setopt SHARE_HISTORY

# Completion cache
autoload -Uz compinit
compinit -C

# Zoxide
eval "$(zoxide init zsh --cmd cd)"

# Source all scripts in rc.d
for rc in "$ZDOTDIR"/rc.d/*.zsh(N); do
  source "$rc"
done

# Compile zshrc
if [[ ! -f $ZDOTDIR/.zshrc.zwc || $ZDOTDIR/.zshrc -nt $ZDOTDIR/.zshrc.zwc ]]; then
  zcompile $ZDOTDIR/.zshrc
fi

[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

# uv installs its tools (graphify, easyeda2kicad) in ~/.local/bin. Homebrew's uv,
# which the bootstrap uses, never writes the env file above, so add the folder here.
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || export PATH="$HOME/.local/bin:$PATH"
