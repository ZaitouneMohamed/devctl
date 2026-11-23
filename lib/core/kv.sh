# shellcheck shell=bash
# kv.sh — read "key = value" files (templates' engine.conf, registry entries) into an
# associative array. Same strict rules as config.sh: literal values, no expansion.

[[ -n ${__DEVCTL_KV_SH:-} ]] && return 0
__DEVCTL_KV_SH=1

# kv_read FILE ARRAY_NAME — fill the associative array ARRAY_NAME (cleared first).
kv_read() {
  local file=$1 line key value lineno=0
  local -n __kv_out=$2
  __kv_out=()
  [[ -r $file ]] || die "$EX_NOTFOUND" "cannot read $file"
  while IFS= read -r line || [[ -n $line ]]; do
    ((++lineno))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^([a-z][a-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] ||
      die "$EX_VALIDATION" "$file:$lineno: invalid line (expected 'key = value')"
    key=${BASH_REMATCH[1]}
    value=$(config__clean_value "${BASH_REMATCH[2]}")
    __kv_out[$key]=$value
  done <"$file"
}

# kv_require ARRAY_NAME FILE KEY... — die unless every KEY is present and non-empty.
kv_require() {
  local -n __kv_in=$1
  local file=$2 key
  shift 2
  for key; do
    [[ -n ${__kv_in[$key]:-} ]] || die "$EX_VALIDATION" "$file: missing '$key'"
  done
}
