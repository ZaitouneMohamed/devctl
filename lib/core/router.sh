# shellcheck shell=bash
# router.sh — global flags, configuration, command dispatch and action history.
#
# devctl NOUN [VERB] [ARGS...] runs cmd_NOUN_VERB from lib/cmd/NOUN.sh, or cmd_NOUN when
# there is no matching verb function. Command files call register_action for every verb
# that changes state; those runs are recorded in history when the process exits.

[[ -n ${__DEVCTL_ROUTER_SH:-} ]] && return 0
__DEVCTL_ROUTER_SH=1

declare -gA __DEVCTL_ACTIONS=()
declare -gA __ROUTER_LOADED=() # command files already sourced
__ROUTER_ACTION=""
__ROUTER_T0=0
__ROUTER_ARGS=()

# register_action NAME... — mark "noun" or "noun.verb" as state-changing.
register_action() {
  local name
  for name; do
    __DEVCTL_ACTIONS[$name]=1
  done
}

# router_mark_action NAME — record the current run in history as action NAME, for
# commands that only sometimes change state (e.g. `dashboard open` starting the server).
router_mark_action() {
  if [[ -z $__ROUTER_ACTION ]]; then
    __ROUTER_T0=$(history_now_us)
    cleanup_add_fn router__record_history
  fi
  __ROUTER_ACTION=$1
}

devctl_main() {
  devctl_init_runtime
  ui_color_init auto

  local -a args=()
  local arg want_help=0 color_flag=""
  while (($#)); do
    arg=$1
    shift
    case $arg in
      --)
        args+=(-- "$@")
        break
        ;;
      --dry-run) DEVCTL_DRY_RUN=1 ;;
      -y | --yes) DEVCTL_ASSUME_YES=1 ;;
      --json) DEVCTL_JSON=1 ;;
      -q | --quiet) DEVCTL_QUIET=1 ;;
      -v | --verbose) DEVCTL_VERBOSE=1 ;;
      --no-color) color_flag=never ;;
      --color=*) color_flag=${arg#*=} ;;
      --confirm=*) DEVCTL_CONFIRM_TEXT=${arg#*=} ;;
      -h | --help) want_help=1 ;;
      *) args+=("$arg") ;;
    esac
  done

  ((DEVCTL_QUIET && DEVCTL_VERBOSE)) && die "$EX_USAGE" "--quiet and --verbose cannot be used together"
  config_load
  [[ -n $color_flag ]] && config_set ui.color "$color_flag"
  ui_color_init "$(config_get ui.color)"
  router__apply_log_levels

  if ((${#args[@]} == 0)); then
    router_usage
    return 0
  fi

  local noun=${args[0]} verb="" fn base consumed=1
  [[ $noun == -* ]] && die "$EX_USAGE" "unknown option '$noun' (see: devctl help)"
  router__load_command "$noun"

  base=cmd_${noun//-/_}
  if ((${#args[@]} > 1)) && is_identifier "${args[1]}" && declare -F -- "${base}_${args[1]//-/_}" >/dev/null; then
    verb=${args[1]}
    fn=${base}_${verb//-/_}
    consumed=2
  elif declare -F -- "$base" >/dev/null; then
    fn=$base
    # `devctl dashboard stp`: a near-miss of a real subcommand is a typo, not an argument.
    if ((${#args[@]} > 1)) && [[ ${args[1]} != -* ]]; then
      local near
      near=$(router__suggest "${args[1]}" "$(router_verbs "$noun")")
      [[ -n $near ]] && die "$EX_USAGE" "unknown subcommand '${args[1]}' for '$noun' — did you mean: $near? (see: devctl help $noun)"
    fi
  else
    local suggestion=""
    [[ -n ${args[1]:-} ]] && suggestion=$(router__suggest "${args[1]}" "$(router_verbs "$noun")")
    die "$EX_USAGE" "unknown subcommand '${args[1]:-}' for '$noun'${suggestion:+ — did you mean: $suggestion?} (see: devctl help $noun)"
  fi

  if ((want_help)); then
    router_help_for "$noun"
    return 0
  fi

  local action=$noun${verb:+.$verb}
  __LOG_CONTEXT="$noun${verb:+ $verb}"
  log_debug "dispatch: $fn"
  if [[ -n ${__DEVCTL_ACTIONS[$action]:-} ]]; then
    __ROUTER_ACTION=$action
    __ROUTER_T0=$(history_now_us)
    __ROUTER_ARGS=("${args[@]:consumed}")
    cleanup_add_fn router__record_history
  fi
  "$fn" "${args[@]:consumed}"
}

router__apply_log_levels() {
  local stderr_level file_level=info
  stderr_level=$(config_get log.level)
  if ((DEVCTL_VERBOSE)); then
    stderr_level=debug file_level=debug
  elif ((DEVCTL_QUIET)); then
    stderr_level=error
  fi
  log_set_levels "$stderr_level" "$file_level"
}

# router__load_command NOUN — source lib/cmd/NOUN.sh. NOUN is validated as an identifier,
# so it can never point outside the command directory.
router__load_command() {
  local noun=$1 file
  file="$DEVCTL_CMD_DIR/$noun.sh"
  if ! is_identifier "$noun" || [[ ! -f $file ]]; then
    local suggestion
    suggestion=$(router__suggest "$noun" "$(router_commands)")
    die "$EX_USAGE" "unknown command '$noun'${suggestion:+ — did you mean: $suggestion?} (see: devctl help)"
  fi
  [[ -n ${__ROUTER_LOADED[$noun]:-} ]] && return 0 # load each command file once
  # shellcheck source=/dev/null  # path is computed; files live in lib/cmd/
  source "$file"
  __ROUTER_LOADED[$noun]=1
}

# Runs from the EXIT trap, so it sees the final exit status.
router__record_history() {
  local now duration_ms
  now=$(history_now_us)
  duration_ms=$(((now - __ROUTER_T0) / 1000))
  history_record_action "$__ROUTER_ACTION" "$__DEVCTL_EXIT_STATUS" "$duration_ms" "${__ROUTER_ARGS[@]}"
}

# router__summary FILE — the "# summary:" line of a command file.
router__summary() {
  local line
  while IFS= read -r line; do
    if [[ $line == "# summary: "* ]]; then
      printf '%s\n' "${line#"# summary: "}"
      return 0
    fi
  done <"$1"
  printf '\n'
}

# router__header FILE KEY — value of a "# KEY: value" line in a command file's header.
router__header() {
  local line
  while IFS= read -r line; do
    [[ $line == \#* || -z $line ]] || break
    if [[ $line == "# $2: "* ]]; then
      printf '%s\n' "${line#"# $2: "}"
      return 0
    fi
  done <"$1"
  return 1
}

# router_commands [--all] — command names, one per line (hidden ones only with --all).
router_commands() {
  local file name
  for file in "$DEVCTL_CMD_DIR"/*.sh; do
    [[ -f $file ]] || continue
    name=${file##*/}
    name=${name%.sh}
    if [[ ${1:-} != --all ]] && [[ $(router__header "$file" hidden) == yes ]]; then
      continue
    fi
    printf '%s\n' "$name"
  done
}

# router_verbs NOUN — subcommands of NOUN (from its cmd_NOUN_VERB functions).
router_verbs() {
  local noun=$1 base fn
  is_identifier "$noun" && [[ -f $DEVCTL_CMD_DIR/$noun.sh ]] || return 0
  router__load_command "$noun"
  base=cmd_${noun//-/_}_
  while read -r _ _ fn; do
    [[ $fn == "$base"* ]] && printf '%s\n' "${fn#"$base"}" | tr _ -
  done < <(declare -F)
  return 0
}

# router__suggest WORD CANDIDATES — candidates that start with WORD or are at most 2 edits
# away, space-separated.
router__suggest() {
  local word=$1 candidate
  local -a found=()
  while IFS= read -r candidate; do
    [[ -n $candidate ]] || continue
    if [[ ${#word} -ge 2 && $candidate == "$word"* ]] || (($(router__distance "$word" "$candidate") <= 2)); then
      found+=("$candidate")
    fi
  done <<<"$2"
  printf '%s' "${found[*]}"
}

# router__distance A B — Levenshtein edit distance (fine for short command names).
router__distance() {
  local a=$1 b=$2 i j cost
  local -a prev=() row=()
  ((${#a} > 32 || ${#b} > 32)) && { printf '99\n'; return 0; }
  for ((j = 0; j <= ${#b}; j++)); do prev[j]=$j; done
  for ((i = 1; i <= ${#a}; i++)); do
    row=("$i")
    for ((j = 1; j <= ${#b}; j++)); do
      cost=1
      [[ ${a:i-1:1} == "${b:j-1:1}" ]] && cost=0
      row[j]=$((prev[j] + 1))
      ((row[j - 1] + 1 < row[j])) && row[j]=$((row[j - 1] + 1))
      ((prev[j - 1] + cost < row[j])) && row[j]=$((prev[j - 1] + cost))
    done
    prev=("${row[@]}")
  done
  printf '%s\n' "${prev[${#b}]}"
}

router_usage() {
  local name
  ui_paint 1 bold "devctl $DEVCTL_VERSION"
  printf ' — Local DevOps Management System\n\n'
  printf 'Usage: devctl [global options] <command> [<subcommand>] [args]\n\n'
  printf 'Commands:\n'
  while IFS= read -r name; do
    printf '  %-12s %s\n' "$name" "$(router__summary "$DEVCTL_CMD_DIR/$name.sh")"
  done < <(router_commands)
  cat <<'EOF'

Global options:
  --dry-run        show what would change, change nothing
  -y, --yes        answer yes to yes/no questions (never to typed confirmations)
  --confirm=TEXT   provide a typed confirmation non-interactively
  --json           machine-readable output (where supported)
  -q, --quiet      only errors and requested output
  -v, --verbose    debug output
  --color=WHEN     auto, always or never (--no-color = never)
  -h, --help       help for a command

Run 'devctl help <command>' for details.
EOF
}

# router_help_for NOUN — print a command's help_NOUN, or its summary if it has none.
router_help_for() {
  local noun=$1
  router__load_command "$noun"
  if declare -F -- "help_${noun//-/_}" >/dev/null; then
    "help_${noun//-/_}"
  else
    printf 'devctl %s — %s\n' "$noun" "$(router__summary "$DEVCTL_CMD_DIR/$noun.sh")"
  fi
}
