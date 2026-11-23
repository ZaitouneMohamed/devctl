# shellcheck shell=bash
# ui.sh — talking to the user: colors, status lines, tables, confirmations.
#
# Status lines go to stdout and are hidden by --quiet and --json. Prompts go to the
# terminal via `read -p` (stderr). Confirmations never read from a pipe.

[[ -n ${__DEVCTL_UI_SH:-} ]] && return 0
__DEVCTL_UI_SH=1

declare -gA __UI_SGR=(
  [reset]=$'\e[0m' [bold]=$'\e[1m' [dim]=$'\e[2m'
  [red]=$'\e[31m' [green]=$'\e[32m' [yellow]=$'\e[33m' [blue]=$'\e[34m' [cyan]=$'\e[36m'
)
__UI_COLOR_OUT=0
__UI_COLOR_ERR=0

# ui_color_init auto|always|never — auto colors a stream only if it is a terminal
# and NO_COLOR (https://no-color.org) is unset.
ui_color_init() {
  __UI_COLOR_OUT=0 __UI_COLOR_ERR=0
  case ${1:-auto} in
    always) __UI_COLOR_OUT=1 __UI_COLOR_ERR=1 ;;
    never) ;;
    auto)
      if [[ -z ${NO_COLOR:-} ]]; then
        [[ -t 1 ]] && __UI_COLOR_OUT=1
        [[ -t 2 ]] && __UI_COLOR_ERR=1
      fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

# ui_paint FD STYLE TEXT — print TEXT (no newline), styled if FD (1 or 2) has color on.
ui_paint() {
  local on=$__UI_COLOR_OUT
  [[ $1 == 2 ]] && on=$__UI_COLOR_ERR
  if ((on)) && [[ -n ${__UI_SGR[$2]:-} ]]; then
    printf '%s%s%s' "${__UI_SGR[$2]}" "$3" "${__UI_SGR[reset]}"
  else
    printf '%s' "$3"
  fi
}

ui__status() { # ui__status STYLE SYMBOL MESSAGE
  ((DEVCTL_QUIET || DEVCTL_JSON)) && return 0
  printf '%s %s\n' "$(ui_paint 1 "$1" "$2")" "$3"
}

ui_step() { ui__status cyan '→' "$*"; }
ui_ok() { ui__status green '✓' "$*"; }
ui_skip() { ui__status dim '–' "$*"; }
ui_fail() { ui__status red '✗' "$*"; }
ui_note() { ui__status yellow '!' "$*"; }

ui_header() {
  ((DEVCTL_QUIET || DEVCTL_JSON)) && return 0
  printf '%s\n' "$(ui_paint 1 bold "$*")"
}

# ui_plan TEXT — a line of a dry-run plan. Shown even with --quiet: it is the output
# the user asked for.
ui_plan() {
  printf '%s %s\n' "$(ui_paint 1 yellow '[dry-run]')" "$*"
}

# ui_table — align tab-separated stdin into columns.
ui_table() {
  column -t -s $'\t'
}

# confirm QUESTION [yes|no] — ask a yes/no question; default answer is "no".
# Returns 0 for yes, 1 for no. --yes answers yes; --dry-run answers yes (nothing is
# executed in a dry run, and the plan should show every step).
confirm() {
  local question=$1 default=${2:-no} hint='[y/N]' reply
  [[ $default == yes ]] && hint='[Y/n]'

  if ((DEVCTL_DRY_RUN)); then
    ui_plan "would ask: $question"
    return 0
  fi
  if ((DEVCTL_ASSUME_YES)); then
    log_info "confirmed by --yes: $question"
    return 0
  fi
  [[ -t 0 ]] || die "$EX_PRECONDITION" "confirmation needed ('$question') but input is not a terminal; run interactively or pass --yes"

  while true; do
    read -r -p "$question $hint " reply || return 1
    case ${reply,,} in
      y | yes) return 0 ;;
      n | no) return 1 ;;
      '')
        [[ $default == yes ]]
        return
        ;;
      *) printf 'Please answer y or n.\n' >&2 ;;
    esac
  done
}

# confirm_or_abort QUESTION [yes|no] — like confirm, but exits with EX_ABORTED on "no".
confirm_or_abort() {
  confirm "$@" || die "$EX_ABORTED" "aborted"
}

# confirm_typed EXPECTED [WHAT] — require the user to type EXPECTED exactly.
# --yes does NOT satisfy it. Non-interactive callers (the dashboard) pass the text with
# --confirm=TEXT, which is compared the same way.
confirm_typed() {
  local expected=$1 what=${2:-$1} reply

  if ((DEVCTL_DRY_RUN)); then
    ui_plan "would ask you to type '$expected' to confirm"
    return 0
  fi
  if [[ -n $DEVCTL_CONFIRM_TEXT ]]; then
    [[ $DEVCTL_CONFIRM_TEXT == "$expected" ]] && return 0
    log_error "confirmation text does not match '$what'"
    return 1
  fi
  [[ -t 0 ]] || die "$EX_PRECONDITION" "typing '$expected' is required but input is not a terminal; use --confirm=$expected"

  read -r -p "Type '$expected' to confirm: " reply || return 1
  [[ $reply == "$expected" ]] && return 0
  log_error "confirmation text does not match '$what'"
  return 1
}
