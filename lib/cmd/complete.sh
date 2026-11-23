# shellcheck shell=bash
# summary: Print Tab-completion candidates (used by the Bash completion script)
# hidden: yes

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

readonly COMPLETE_GLOBAL_FLAGS="--dry-run --yes --confirm= --json --quiet --verbose --color= --no-color --help"

# devctl complete -- WORD... — WORDs are the command line after "devctl"; the last one is
# the word being completed (possibly empty). Prints matching candidates, one per line.
#
# Commands can add their own candidates with an optional function:
#   complete_NOUN flags VERB     → flags for that subcommand
#   complete_NOUN args VERB N    → values for the Nth argument after the subcommand
cmd_complete() {
  [[ ${1:-} == -- ]] && shift
  (($#)) || set -- ""
  local cur=${!#} word noun="" verb="" hook=""
  local -a words=("${@:1:$#-1}") positional=() candidates=()

  for word in "${words[@]}"; do
    [[ $word == -* ]] || positional+=("$word")
  done
  ((${#positional[@]} > 0)) && noun=${positional[0]}
  if [[ -n $noun ]] && is_identifier "$noun" && [[ -f $DEVCTL_CMD_DIR/$noun.sh ]]; then
    router__load_command "$noun"
    hook=complete_${noun//-/_}
    declare -F -- "$hook" >/dev/null || hook=""
  elif [[ -n $noun ]]; then
    return 0 # unknown command: nothing to offer
  fi

  if [[ $cur == --color=* ]]; then
    candidates=(--color=auto --color=always --color=never)
  elif [[ $cur == -* ]]; then
    read -ra candidates <<<"$COMPLETE_GLOBAL_FLAGS"
    if [[ -n $hook ]]; then
      verb=${positional[1]:-}
      mapfile -t -O "${#candidates[@]}" candidates < <("$hook" flags "$verb")
    fi
  elif ((${#positional[@]} == 0)); then
    mapfile -t candidates < <(router_commands)
  elif ((${#positional[@]} == 1)); then
    mapfile -t candidates < <(router_verbs "$noun")
    [[ -n $hook ]] && mapfile -t -O "${#candidates[@]}" candidates < <("$hook" args "" 1)
  elif [[ -n $hook ]]; then
    verb=${positional[1]}
    mapfile -t candidates < <("$hook" args "$verb" "$((${#positional[@]} - 1))")
  fi

  for word in "${candidates[@]}"; do
    [[ -n $word && $word == "$cur"* ]] && printf '%s\n' "$word"
  done
  return 0
}
