# shellcheck shell=bash
# validate.sh — input validators. Each is_* returns 0 if valid, 1 if not, and prints nothing.
# require_valid TYPE VALUE LABEL dies with EX_VALIDATION on invalid input.

[[ -n ${__DEVCTL_VALIDATE_SH:-} ]] && return 0
__DEVCTL_VALIDATE_SH=1

# Project name / domain label: 2–42 chars, lowercase letters, digits, inner hyphens,
# starts with a letter. Short enough to derive DB and user names from it.
is_domain_label() { [[ $1 =~ ^[a-z][a-z0-9-]{0,40}[a-z0-9]$ && $1 != *--* ]]; }

# Domain suffix: a single DNS label (e.g. "test").
is_domain_suffix() { [[ $1 =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

# Hostname: one lowercase DNS label (e.g. zaitoune-laptop).
is_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

# Identifier for templates, engines, commands, locks: lowercase words joined by hyphens.
is_identifier() { [[ ${#1} -le 64 && $1 =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; }

# Unsigned integer without leading zeros (max 18 digits, safe for Bash arithmetic).
is_uint() { [[ $1 =~ ^(0|[1-9][0-9]{0,17})$ ]]; }

is_percent() { is_uint "$1" && (($1 <= 100)); }

is_port() { is_uint "$1" && (($1 >= 1 && $1 <= 65535)); }

is_bool() { [[ ${1,,} =~ ^(true|false|yes|no|on|off|1|0)$ ]]; }

# bool_true VALUE — status 0 if VALUE is a true-ish boolean.
bool_true() { [[ ${1,,} =~ ^(true|yes|on|1)$ ]]; }

# Version like 8, 8.4, 8.4.1.
is_version() { [[ $1 =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; }

is_abs_path() { [[ $1 == /* && $1 != *$'\n'* ]]; }

# path_is_within ROOT PATH — PATH (after resolving .., symlinks) is ROOT or below it.
path_is_within() {
  local root path
  root=$(realpath -m -- "$1") || return 1
  path=$(realpath -m -- "$2") || return 1
  [[ $path == "$root" || $path == "$root"/* ]]
}

# is_in_list VALUE WORD... — VALUE equals one of the words.
is_in_list() {
  local value=$1 word
  shift
  for word; do
    [[ $value == "$word" ]] && return 0
  done
  return 1
}

declare -gA __VALIDATORS=(
  [domain_label]=is_domain_label
  [domain_suffix]=is_domain_suffix
  [hostname]=is_hostname
  [identifier]=is_identifier
  [uint]=is_uint
  [percent]=is_percent
  [port]=is_port
  [bool]=is_bool
  [version]=is_version
  [abs_path]=is_abs_path
)

declare -gA __VALIDATOR_HINTS=(
  [domain_label]="2-42 lowercase letters, digits or single hyphens, starting with a letter"
  [domain_suffix]="a single lowercase DNS label, e.g. test"
  [hostname]="lowercase letters, digits and hyphens, e.g. zaitoune-laptop"
  [identifier]="lowercase words joined by hyphens"
  [uint]="a whole number"
  [percent]="a whole number from 0 to 100"
  [port]="a port number from 1 to 65535"
  [bool]="true/false, yes/no, on/off or 1/0"
  [version]="a version like 8, 8.4 or 8.4.1"
  [abs_path]="an absolute path"
)

# is_valid TYPE VALUE
is_valid() {
  local fn=${__VALIDATORS[$1]:-}
  [[ -n $fn ]] || die "$EX_FAIL" "unknown validator type '$1' (bug)"
  "$fn" "$2"
}

# require_valid TYPE VALUE LABEL — die with a helpful message if VALUE is invalid.
require_valid() {
  is_valid "$1" "$2" && return 0
  die "$EX_VALIDATION" "invalid ${3:-value} '$2': expected ${__VALIDATOR_HINTS[$1]}"
}
