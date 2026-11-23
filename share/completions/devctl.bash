# shellcheck shell=bash
# Bash Tab completion for devctl.
# Installed by `devctl self install` as ~/.local/share/bash-completion/completions/devctl.
# Candidates come from `devctl complete`, so they always match the installed commands.

_devctl() {
  # prev is set by _init_completion (bash-completion's API); devctl does not need it.
  # shellcheck disable=SC2034
  local cur prev words cword bin
  if declare -F _init_completion >/dev/null; then
    # -n = keeps "--color=al" as one word instead of splitting at "=".
    _init_completion -n = || return
  else
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
    cur=${COMP_WORDS[COMP_CWORD]}
  fi

  bin=${words[0]}
  # A path typed as ~/... reaches us unexpanded; expand it to run it.
  # shellcheck disable=SC2088
  [[ $bin == "~/"* ]] && bin="$HOME/${bin#"~/"}"
  command -v -- "$bin" >/dev/null || bin=devctl

  local -a candidates=()
  mapfile -t candidates < <("$bin" complete -- "${words[@]:1:cword}" 2>/dev/null)
  COMPREPLY=("${candidates[@]}")

  # Bash splits words at "=" (COMP_WORDBREAKS) and only replaces the part after it,
  # so "--color=al" must be completed with "always", not "--color=always".
  if [[ $cur == *=* && $COMP_WORDBREAKS == *=* ]]; then
    COMPREPLY=("${COMPREPLY[@]#"${cur%%=*}="}")
  fi

  # Options that take a value end with "=": don't add a space after them.
  if ((${#COMPREPLY[@]} == 1)) && [[ ${COMPREPLY[0]} == *= ]]; then
    compopt -o nospace 2>/dev/null
  fi
}

complete -F _devctl devctl
