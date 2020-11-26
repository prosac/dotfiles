# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

# Path to your oh-my-zsh installation.
export ZSH=/Users/johannes.vonbargen/.oh-my-zsh

# Set name of the theme to load. Optionally, if you set this to "random"
# it'll load a random theme each time that oh-my-zsh is loaded.
# See https://github.com/robbyrussell/oh-my-zsh/wiki/Themes
ZSH_THEME="agnoster"

# Set list of themes to load
# Setting this variable when ZSH_THEME=random
# cause zsh load theme from this variable instead of
# looking in ~/.oh-my-zsh/themes/
# An empty array have no effect
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion. Case
# sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment the following line to disable bi-weekly auto-update checks.
# DISABLE_AUTO_UPDATE="true"

# Uncomment the following line to change how often to auto-update (in days).
# export UPDATE_ZSH_DAYS=13

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# The optional three formats: "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load? (plugins can be found in ~/.oh-my-zsh/plugins/*)
# Custom plugins may be added to ~/.oh-my-zsh/custom/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(
  git
)

source $ZSH/oh-my-zsh.sh

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='nvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# ssh
# export SSH_KEY_PATH="~/.ssh/rsa_id"

# Set personal aliases, overriding those provided by oh-my-zsh libs,
# plugins, and themes. Aliases can be placed here, though oh-my-zsh
# users are encouraged to define aliases within the ZSH_CUSTOM folder.
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"
alias be='bundle exec'
export BACKEND_HOST="vm1-johannes-vonbargen.env.xing.com"

# export PATH=/Users/johannes.vonbargen/.local/bin:$PATH
# export PATH="~/.rbenv/bin:~/.rbenv/shims:/usr/local/bin:/usr/bin:/bin:/usr/local/opt/mysql@5.7/bin:$PATH"

# export PATH="$HOME/bin:$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init -)"
# export PATH="~/.oly/bin:$PATH"

alias f='fzf'
alias cdfst=cd\ /Users/johannes.vonbargen/Projects/profile-api_fullstack_tests
alias cdpb=cd\ /Users/johannes.vonbargen/Projects/profile-backend
alias cdpm=cd\ /Users/johannes.vonbargen/Projects/profile-modules
alias cdp=cd\ /Users/johannes.vonbargen/Projects/profile
alias cdps=cd\ /Users/johannes.vonbargen/Projects/profile-stability
alias cdpf=cd\ /Users/johannes.vonbargen/Projects/profile-photos
alias cdpaws=cd\ /Users/johannes.vonbargen/Projects/profile-images-aws
alias rspec='be rspec'
alias kc=kubectl
alias kctx=kubectx
alias config='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

kube_prompt()
{
   kubectl_current_context=$(kubectl config current-context)
   kubectl_prompt="( \u2388 $kubectl_current_context )"
   echo $kubectl_prompt
}

RPROMPT='%F{81}$(kube_prompt)'

export PATH="/Users/johannes.vonbargen/.oly/bin:/bin:/bin:$HOME/.config/yarn/global/node_modules/.bin:$HOME/Library/Android/sdk/platform-tools:~/.emacs.d/bin:/Applications/sonar-scanner-4.5.0.2216-macosx/bin/:$PATH"
# export EDITOR="nvim"
export EDITOR=e # spacemacs
export LDFLAGS="-L/usr/local/opt/openssl@1.1/lib"
export CPPFLAGS="-I/usr/local/opt/openssl@1.1/include"
export GTAGSLABEL=pygments

export NVM_DIR="$HOME/.nvm"
[ -s "/usr/local/opt/nvm/nvm.sh" ] && . "/usr/local/opt/nvm/nvm.sh"  # This loads nvm
[ -s "/usr/local/opt/nvm/etc/bash_completion.d/nvm" ] && . "/usr/local/opt/nvm/etc/bash_completion.d/nvm"  # This loads nvm bash_completion

export XINGBOX_NAME=vm1-johannes-vonbargen
export PATH="/usr/local/sbin:$PATH"
