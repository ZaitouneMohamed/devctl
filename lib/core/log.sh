# shellcheck shell=bash
# log.sh — diagnostics. log_* write to stderr (filtered by level) and to a daily log file.
#
# log_* is for diagnostics; talking to the user is ui.sh's job (stdout).
# Every message is redacted before it is written anywhere.

[[ -n ${__DEVCTL_LOG_SH:-} ]] && return 0
__DEVCTL_LOG_SH=1

declare -gA __LOG_RANK=([debug]=10 [info]=20 [warn]=30 [error]=40)
__LOG_STDERR_LEVEL=warn # set from config log.level, --verbose, --quiet
__LOG_FILE_LEVEL=info   # debug with --verbose
__LOG_FILE_BROKEN=0
__LOG_CONTEXT="" # current command, e.g. "site create"

log_debug() { log__emit debug "$*"; }
log_info() { log__emit info "$*"; }
log_warn() { log__emit warn "$*"; }
log_error() { log__emit error "$*"; }

# log_set_levels STDERR_LEVEL FILE_LEVEL
log_set_levels() {
  [[ -n ${__LOG_RANK[$1]:-} && -n ${__LOG_RANK[$2]:-} ]] || return 1
  __LOG_STDERR_LEVEL=$1
  __LOG_FILE_LEVEL=$2
}

# log_file_path — today's log file.
log_file_path() {
  local day
  printf -v day '%(%Y-%m-%d)T' -1
  printf '%s/devctl-%s.log\n' "$DEVCTL_LOG_DIR" "$day"
}

# log_redact TEXT — mask secrets: key=value / key: value where the key looks secret,
# and user:password@ in URLs. Prefers over-masking to leaking.
log_redact() {
  sed -E \
    -e 's/([[:alnum:]_.-]*(pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential)[[:alnum:]_.-]*)([[:space:]]*[=:][[:space:]]*)("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)/\1\4****/Ig' \
    -e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#\1****@#g' \
    <<<"$1"
}

log__emit() {
  local level=$1 message prefix style
  message=$(log_redact "$2")

  if ((__LOG_RANK[$level] >= __LOG_RANK[$__LOG_STDERR_LEVEL])); then
    case $level in
      debug) prefix="debug:" style=dim ;;
      info) prefix="info:" style=blue ;;
      warn) prefix="warning:" style=yellow ;;
      error) prefix="error:" style=red ;;
    esac
    printf '%s %s\n' "$(ui_paint 2 "$style" "$prefix")" "$message" >&2
  fi

  if ((__LOG_RANK[$level] >= __LOG_RANK[$__LOG_FILE_LEVEL])); then
    log__to_file "$level" "$message"
  fi
}

log__to_file() {
  ((__LOG_FILE_BROKEN)) && return 0
  local file stamp
  file=$(log_file_path)
  printf -v stamp '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  if ! {
    ensure_private_dir "$DEVCTL_LOG_DIR"
    printf '%s devctl[%d] %-5s %s%s\n' "$stamp" "$$" "$1" "${__LOG_CONTEXT:+($__LOG_CONTEXT) }" "$2" >>"$file"
  } 2>/dev/null; then
    __LOG_FILE_BROKEN=1
    printf 'warning: cannot write log file %s; continuing without file logging\n' "$file" >&2
  fi
}

# log_prune DAYS — keep DAYS days of devctl's own daily log files, delete older ones.
# find -mtime counts whole 24h periods, so "+(DAYS-1)" means "at least DAYS days old".
log_prune() {
  is_uint "$1" && (($1 >= 1)) || return 1
  [[ -d $DEVCTL_LOG_DIR ]] || return 0
  find "$DEVCTL_LOG_DIR" -maxdepth 1 -type f -name 'devctl-*.log' -mtime "+$(($1 - 1))" -delete
}
