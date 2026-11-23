# shellcheck shell=bash
# history.sh — append-only record of actions and alerts (JSON Lines).
#
# Every state-changing command run from any source (terminal, dashboard, timer, git hook)
# is recorded here; the dashboard indexes this file but never writes it directly.
# History must never break a command: failures here only produce a warning.

[[ -n ${__DEVCTL_HISTORY_SH:-} ]] && return 0
__DEVCTL_HISTORY_SH=1

readonly __HISTORY_SOURCES="cli dashboard timer hook"

# history_source — who is running devctl, from DEVCTL_SOURCE (set by the dashboard,
# timer and hooks); defaults to cli.
history_source() {
  local source=${DEVCTL_SOURCE:-cli}
  # shellcheck disable=SC2086  # word-split the fixed list on purpose
  if ! is_in_list "$source" $__HISTORY_SOURCES; then
    log_warn "unknown DEVCTL_SOURCE '$source'; recording as cli"
    source=cli
  fi
  printf '%s\n' "$source"
}

# history_redact_args OUT_ARRAY ARGS... — copy ARGS into OUT_ARRAY with secret values
# masked: "--password x", "--password=x" and KEY=value forms.
history_redact_args() {
  local -n __hr_out=$1
  shift
  local arg lower mask_next=0 secret_re='(pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential)'
  __hr_out=()
  for arg; do
    lower=${arg,,}
    if ((mask_next)); then
      __hr_out+=('****')
      mask_next=0
    elif [[ $lower =~ ^--[a-z0-9-]*${secret_re}[a-z0-9-]*$ ]]; then
      __hr_out+=("$arg")
      mask_next=1
    elif [[ $lower == --*=* && ${lower%%=*} =~ $secret_re ]]; then
      __hr_out+=("${arg%%=*}=****")
    else
      __hr_out+=("$(log_redact "$arg")")
    fi
  done
}

# history_record_action ACTION EXIT_STATUS DURATION_MS ARGS...
history_record_action() {
  local action=$1 status=$2 duration=$3 result line
  shift 3
  local -a args=()
  history_redact_args args "$@"

  if ((DEVCTL_DRY_RUN)); then
    result=dry-run
  elif ((status == 0)); then
    result=ok
  elif ((status == EX_ABORTED)); then
    result=aborted
  else
    result=failed
  fi

  line=$(jq -nc \
    --arg ts "$(history__timestamp)" \
    --arg source "$(history_source)" \
    --arg action "$action" \
    --argjson args "$(json_array "${args[@]}")" \
    --arg result "$result" \
    --argjson exit "$status" \
    --argjson duration_ms "$duration" \
    '{type: "action", ts: $ts, source: $source, action: $action, args: $args,
      result: $result, exit: $exit, duration_ms: $duration_ms}') || {
    log_warn "could not record history for '$action'"
    return 0
  }
  history__append "$line"
}

# history_record_alert LEVEL CODE MESSAGE — e.g. warn disk-low "12% free on /home".
history_record_alert() {
  local level=$1 code=$2 message line
  is_in_list "$level" info warn error || die "$EX_FAIL" "invalid alert level '$level' (bug)"
  is_identifier "$code" || die "$EX_FAIL" "invalid alert code '$code' (bug)"
  message=$(log_redact "$3")
  line=$(jq -nc \
    --arg ts "$(history__timestamp)" \
    --arg source "$(history_source)" \
    --arg level "$level" \
    --arg code "$code" \
    --arg message "$message" \
    '{type: "alert", ts: $ts, source: $source, level: $level, code: $code, message: $message}') || {
    log_warn "could not record alert '$code'"
    return 0
  }
  history__append "$line"
}

history__timestamp() {
  local ts
  printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  printf '%s\n' "$ts"
}

# history__append LINE — append one line under an exclusive flock on the file itself.
history__append() {
  local fd
  if ! {
    ensure_private_dir "${DEVCTL_HISTORY_FILE%/*}" &&
      exec {fd}>>"$DEVCTL_HISTORY_FILE" &&
      flock -w 5 "$fd" &&
      printf '%s\n' "$1" >&"$fd"
  } 2>/dev/null; then
    log_warn "could not write history file $DEVCTL_HISTORY_FILE"
  fi
  [[ -n ${fd:-} ]] && exec {fd}>&-
  return 0
}

# history_now_us — monotonic-enough wall clock in microseconds (no fork).
# EPOCHREALTIME uses the locale's decimal separator, so strip either . or ,
history_now_us() {
  printf '%s\n' "${EPOCHREALTIME/[.,]/}"
}
