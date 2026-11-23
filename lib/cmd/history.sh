# shellcheck shell=bash
# summary: Show or clear the history of actions and alerts

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action history.clear

cmd_history() {
  cmd_history_list "$@"
}

cmd_history_list() {
  local limit=50 type=""
  while (($#)); do
    case $1 in
      --limit)
        (($# >= 2)) || die "$EX_USAGE" "--limit needs a number"
        limit=$2
        shift 2
        ;;
      --limit=*)
        limit=${1#*=}
        shift
        ;;
      --actions)
        type=action
        shift
        ;;
      --alerts)
        type=alert
        shift
        ;;
      *) die "$EX_USAGE" "usage: devctl history [list] [--limit N] [--actions|--alerts]" ;;
    esac
  done
  require_valid uint "$limit" "--limit"

  local -a events=()
  if [[ -s $DEVCTL_HISTORY_FILE ]]; then
    mapfile -t events < <(jq -c --arg type "$type" 'select($type == "" or .type == $type)' "$DEVCTL_HISTORY_FILE" | tail -n "$limit")
  fi

  if ((DEVCTL_JSON)); then
    printf '%s\n' "${events[@]}" | jq -s 'map(select(. != null))'
    return 0
  fi
  if ((${#events[@]} == 0)); then
    ui_skip "no history yet"
    return 0
  fi
  {
    printf 'TIME\tFROM\tWHAT\tRESULT\tDETAILS\n'
    printf '%s\n' "${events[@]}" | jq -r '
      [ .ts, .source,
        (if .type == "action" then .action else .code end),
        (if .type == "action" then .result else .level end),
        (if .type == "action" then (.args | join(" ")) else .message end) // ""
      ] | map(if . == "" then "-" else . end) | @tsv'
  } | ui_table
}

cmd_history_clear() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl history clear"
  if [[ ! -s $DEVCTL_HISTORY_FILE ]]; then
    ui_skip "history is already empty"
    ((DEVCTL_JSON)) && jq -nc '{cleared: false}'
    return 0
  fi
  ui_note "This permanently deletes all recorded actions and alerts."
  confirm_typed history || die "$EX_ABORTED" "aborted; history kept"
  # flock on the file itself: the same lock history__append uses.
  run_change --desc "Clear history" -- flock -w 5 "$DEVCTL_HISTORY_FILE" truncate -s 0 -- "$DEVCTL_HISTORY_FILE" ||
    die "$EX_EXTERNAL" "could not clear history"
  ui_ok "History cleared (this clear is recorded as the first new entry)"
  ((DEVCTL_JSON)) && jq -nc '{cleared: true}'
  return 0
}

help_history() {
  cat <<'HELP'
Usage: devctl history [list] [--limit N] [--actions|--alerts]   newest last (default 50)
       devctl history clear                                       delete all (type "history")

Every state-changing devctl command is recorded, whether run from the terminal, the
dashboard, the background timer or a git hook. Secrets in arguments are masked.
File: ~/.local/state/devctl/history.jsonl (one JSON object per line).
HELP
}

complete_history() {
  if [[ $1 == flags && ($2 == "" || $2 == list || $2 == --*) ]]; then
    printf '%s\n' --limit --actions --alerts
  fi
  return 0
}
