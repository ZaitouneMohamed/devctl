# shellcheck shell=bash
# errors.sh — exit codes, die(), strict mode, ERR/EXIT/signal traps, cleanup registry.

[[ -n ${__DEVCTL_ERRORS_SH:-} ]] && return 0
__DEVCTL_ERRORS_SH=1

# Exit codes (documented in README "Exit codes"). Never reuse a number for another meaning.
readonly EX_OK=0
readonly EX_FAIL=1
readonly EX_USAGE=2
readonly EX_VALIDATION=3
readonly EX_NOTFOUND=4
readonly EX_CONFLICT=5
readonly EX_ABORTED=6
readonly EX_PRECONDITION=7
readonly EX_PRIVILEGE=8
readonly EX_EXTERNAL=9

# Cleanup registry, run in reverse order by the EXIT trap.
__DEVCTL_CLEANUP_FNS=()
__DEVCTL_CLEANUP_PATHS=()
__DEVCTL_EXIT_STATUS=0
__DEVCTL_TMP_PREFIX="${TMPDIR:-/tmp}/devctl."

# die CODE MESSAGE... — log an error and exit with CODE.
die() {
  local code=$1
  shift
  log_error "$*"
  exit "$code"
}

# cleanup_add_fn NAME — run function NAME at exit. Its exit status is ignored.
# The final exit status is available to it as $__DEVCTL_EXIT_STATUS.
cleanup_add_fn() {
  declare -F -- "$1" >/dev/null || die "$EX_FAIL" "cleanup_add_fn: '$1' is not a function (bug)"
  __DEVCTL_CLEANUP_FNS+=("$1")
}

# make_temp_file VAR / make_temp_dir VAR — create a private temp file/dir, store its path
# in VAR and delete it at exit. Uses a nameref instead of printing the path, because
# $(make_temp_file) would run in a subshell and the cleanup registration would be lost.
make_temp_file() {
  local -n __mt_ref=$1
  __mt_ref=$(mktemp "${__DEVCTL_TMP_PREFIX}XXXXXXXX")
  __DEVCTL_CLEANUP_PATHS+=("$__mt_ref")
}

make_temp_dir() {
  local -n __mt_ref=$1
  __mt_ref=$(mktemp -d "${__DEVCTL_TMP_PREFIX}XXXXXXXX")
  __DEVCTL_CLEANUP_PATHS+=("$__mt_ref")
}

# devctl_init_runtime — strict mode and traps. Called once by the entry point.
devctl_init_runtime() {
  set -Eeuo pipefail
  shopt -s inherit_errexit
  umask 077
  trap 'err__on_err "$?" "$BASH_COMMAND"' ERR
  trap 'err__on_exit' EXIT
  trap 'err__on_signal 130' INT
  trap 'err__on_signal 143' TERM
}

err__on_err() {
  local status=$1 command=$2 i
  # `x=$(fn)` where fn called die(): the subshell already printed the real error and its
  # exit code (2-9) is one of ours, so don't add a confusing "unexpected failure" line.
  if [[ $command == *'$('* ]] && ((status >= EX_USAGE && status <= EX_EXTERNAL)); then
    log_debug "propagating exit $status from: $command"
    return 0
  fi
  log_error "unexpected failure (exit $status) in '${command}' at ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}"
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    log_debug "  at ${FUNCNAME[i]} (${BASH_SOURCE[i]}:${BASH_LINENO[i - 1]})"
  done
}

err__on_signal() {
  printf '\n' >&2
  log_warn "interrupted"
  exit "$1"
}

err__on_exit() {
  local status=$? i path
  __DEVCTL_EXIT_STATUS=$status
  set +e
  trap - ERR
  for ((i = ${#__DEVCTL_CLEANUP_FNS[@]} - 1; i >= 0; i--)); do
    "${__DEVCTL_CLEANUP_FNS[i]}"
  done
  for path in "${__DEVCTL_CLEANUP_PATHS[@]}"; do
    # Only ever delete what make_temp_* created.
    [[ $path == "$__DEVCTL_TMP_PREFIX"* ]] && rm -rf -- "$path"
  done
  exit "$status"
}
