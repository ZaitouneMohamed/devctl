# shellcheck shell=bash
# config.sh — layered configuration: defaults < user file < DEVCTL_CFG_* env < flags.
#
# Files use "key = value" lines. Values are literal text: they are never sourced,
# expanded or evaluated. Every key must exist in share/defaults.conf, where a
# "# @type TYPE" comment line above a key declares how its value is validated.

[[ -n ${__DEVCTL_CONFIG_SH:-} ]] && return 0
__DEVCTL_CONFIG_SH=1

declare -gA DEVCTL_CFG=()   # key -> value
declare -gA __CFG_ORIGIN=() # key -> default | user | env | flag
declare -gA __CFG_TYPE=()   # key -> type (from @type annotations)

DEVCTL_DEFAULTS_FILE="$DEVCTL_ROOT/share/defaults.conf"
DEVCTL_USER_CONFIG="$DEVCTL_CONFIG_DIR/devctl.conf"

# config_load — read all layers and validate. Safe to call again (starts fresh).
config_load() {
  DEVCTL_CFG=() __CFG_ORIGIN=() __CFG_TYPE=()
  config__parse_file "$DEVCTL_DEFAULTS_FILE" default
  if [[ -e $DEVCTL_USER_CONFIG ]]; then
    config__check_file_safety "$DEVCTL_USER_CONFIG"
    config__parse_file "$DEVCTL_USER_CONFIG" user
  fi
  config__apply_env
  config__validate_all
}

# config__parse_file FILE ORIGIN
config__parse_file() {
  local file=$1 origin=$2 line key value pending_type="" lineno=0
  [[ -r $file ]] || die "$EX_PRECONDITION" "cannot read config file $file"

  while IFS= read -r line || [[ -n $line ]]; do
    ((++lineno))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"} # trim leading whitespace
    line=${line%"${line##*[![:space:]]}"} # trim trailing whitespace

    if [[ $origin == default && $line =~ ^#[[:space:]]*@type[[:space:]]+([^[:space:]]+)$ ]]; then
      pending_type=${BASH_REMATCH[1]}
      continue
    fi
    [[ -z $line || $line == \#* ]] && continue

    if [[ ! $line =~ ^([a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      die "$EX_VALIDATION" "$file:$lineno: invalid line (expected 'key = value')"
    fi
    key=${BASH_REMATCH[1]}
    value=$(config__clean_value "${BASH_REMATCH[3]}")

    if [[ $origin == default ]]; then
      __CFG_TYPE[$key]=${pending_type:-string}
      pending_type=""
    elif [[ -z ${__CFG_ORIGIN[$key]:-} ]]; then
      log_warn "$file:$lineno: unknown setting '$key' ignored"
      continue
    fi
    DEVCTL_CFG[$key]=$value
    __CFG_ORIGIN[$key]=$origin
  done <"$file"
}

# config__clean_value RAW — strip surrounding double quotes, or a trailing " # comment".
config__clean_value() {
  local value=$1
  if [[ $value =~ ^\"(.*)\"$ ]]; then
    value=${BASH_REMATCH[1]}
  elif [[ $value =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
    value=${BASH_REMATCH[1]}
  elif [[ $value == \#* ]]; then
    value=""
  fi
  printf '%s' "$value"
}

# The user config must belong to the user and must not be writable by others,
# otherwise another account could change what devctl does.
config__check_file_safety() {
  local file=$1 owner mode
  read -r owner mode < <(stat -L -c '%u %a' -- "$file")
  ((owner == EUID)) || die "$EX_PRECONDITION" "$file is not owned by you; refusing to use it"
  ((8#$mode & 8#022)) && die "$EX_PRECONDITION" "$file is writable by group/others; fix with: chmod 600 '$file'"
  return 0
}

# config__env_name KEY — env var that overrides KEY: dots to underscores, upper case.
config__env_name() {
  local name=${1//./_}
  printf 'DEVCTL_CFG_%s' "${name^^}"
}

config__apply_env() {
  local key var
  for key in "${!DEVCTL_CFG[@]}"; do
    var=$(config__env_name "$key")
    if [[ -v $var ]]; then
      DEVCTL_CFG[$key]=${!var}
      __CFG_ORIGIN[$key]="env"
    fi
  done
}

config__validate_all() {
  local key
  for key in "${!DEVCTL_CFG[@]}"; do
    config__validate_key "$key" "${DEVCTL_CFG[$key]}" ||
      die "$EX_VALIDATION" "setting '$key' = '${DEVCTL_CFG[$key]}' (from ${__CFG_ORIGIN[$key]}) is invalid: expected $(config__type_hint "$key")"
  done
}

# config__validate_key KEY VALUE — check VALUE against KEY's declared type.
config__validate_key() {
  local type=${__CFG_TYPE[$1]:-string} value=$2 word
  case $type in
    string) [[ $value != *$'\n'* ]] ;;
    enum:*)
      local IFS=,
      # shellcheck disable=SC2086  # split the enum list on commas on purpose
      is_in_list "$value" ${type#enum:}
      ;;
    path)
      # shellcheck disable=SC2088  # a literal "~" in the value is what we are checking for
      [[ $value == "~" || $value == "~/"* || $value == /* ]]
      ;;
    words)
      for word in $value; do
        is_identifier "$word" || return 1
      done
      ;;
    *)
      [[ -n ${__VALIDATORS[$type]:-} ]] || die "$EX_FAIL" "unknown @type '$type' for '$1' in defaults.conf (bug)"
      is_valid "$type" "$value"
      ;;
  esac
}

config__type_hint() {
  local type=${__CFG_TYPE[$1]:-string}
  case $type in
    enum:*) printf 'one of %s' "${type#enum:}" ;;
    path) printf 'an absolute path or one starting with ~/' ;;
    words) printf 'space-separated identifiers' ;;
    string) printf 'a single line of text' ;;
    *) printf '%s' "${__VALIDATOR_HINTS[$type]:-$type}" ;;
  esac
}

config__require_key() {
  [[ -n ${__CFG_ORIGIN[$1]:-} ]] || die "$EX_FAIL" "unknown setting '$1' (bug: add it to share/defaults.conf)"
}

# config_get KEY — print the value of KEY.
config_get() {
  config__require_key "$1"
  printf '%s\n' "${DEVCTL_CFG[$1]}"
}

# config_get_bool KEY — status 0 if true.
config_get_bool() {
  config__require_key "$1"
  bool_true "${DEVCTL_CFG[$1]}"
}

# config_get_path KEY — print the value with a leading ~ expanded to $HOME.
config_get_path() {
  config__require_key "$1"
  local value=${DEVCTL_CFG[$1]}
  # shellcheck disable=SC2088  # matching a literal "~" in the value
  case $value in
    "~") value=$HOME ;;
    "~/"*) value="$HOME/${value#"~/"}" ;;
  esac
  printf '%s\n' "$value"
}

# config_origin KEY — where the current value came from.
config_origin() {
  config__require_key "$1"
  printf '%s\n' "${__CFG_ORIGIN[$1]}"
}

# config_set KEY VALUE — override for this run (used by command-line flags).
config_set() {
  config__require_key "$1"
  config__validate_key "$1" "$2" ||
    die "$EX_VALIDATION" "invalid value '$2' for '$1': expected $(config__type_hint "$1")"
  DEVCTL_CFG[$1]=$2
  __CFG_ORIGIN[$1]=flag
}

# config_keys — all known keys, sorted.
config_keys() {
  printf '%s\n' "${!DEVCTL_CFG[@]}" | LC_ALL=C sort
}
