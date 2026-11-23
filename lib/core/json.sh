# shellcheck shell=bash
# json.sh — build JSON from shell values without string concatenation.
#
# Never pass user data to jq with `--args`: jq keeps parsing options after it, so a value
# like "--password" is taken as an unknown jq option and the whole call fails.

[[ -n ${__DEVCTL_JSON_SH:-} ]] && return 0
__DEVCTL_JSON_SH=1

# json_array VALUE... — print a JSON array of strings. Values are sent to jq as
# NUL-separated data on stdin, so any byte sequence (newlines, quotes, leading --) is safe.
json_array() {
  if (($# == 0)); then
    printf '[]\n'
    return 0
  fi
  printf '%s\0' "$@" | jq -cRs 'split("\u0000")[:-1]'
}
