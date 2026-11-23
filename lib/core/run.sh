# shellcheck shell=bash
# run.sh — the single path for commands that CHANGE something.
#
# Read-only commands (ls, docker ps, ss …) are called directly. Anything that changes
# state goes through run_change, so --dry-run, logging and redaction apply everywhere.
# Commands are always argv arrays; nothing is ever built as a string and re-parsed.

[[ -n ${__DEVCTL_RUN_SH:-} ]] && return 0
__DEVCTL_RUN_SH=1

# quote_argv ARGS... — print the arguments as one shell-quoted line, for display only.
quote_argv() {
  local arg quoted out=""
  for arg; do
    printf -v quoted '%q' "$arg"
    out+="${out:+ }$quoted"
  done
  printf '%s\n' "$out"
}

# run_change [--desc TEXT] [--] COMMAND [ARGS...]
# In dry-run mode print the command instead of running it. Otherwise log and run it,
# and return its exit status (the caller decides whether a failure is fatal).
run_change() {
  local desc="" shown status=0
  while (($#)); do
    case $1 in
      --desc)
        desc=$2
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done
  (($#)) || die "$EX_FAIL" "run_change: no command given (bug)"

  shown=$(quote_argv "$@")
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "${desc:+$desc: }$shown"
    return 0
  fi

  log_info "run: $shown"
  "$@" || status=$?
  ((status == 0)) || log_error "command failed (exit $status): $shown"
  return "$status"
}
