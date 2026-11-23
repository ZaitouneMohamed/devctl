# shellcheck shell=bash
# adapter.sh — load the configured implementation of a replaceable part (ADR-0006).
#
# adapter_load KIND sources lib/adapters/KIND/<name>.sh, where <name> comes from the
# setting KIND.adapter (e.g. engine.adapter = docker). Every adapter of one kind defines
# the same functions, so the rest of devctl never knows which one is in use.

[[ -n ${__DEVCTL_ADAPTER_SH:-} ]] && return 0
__DEVCTL_ADAPTER_SH=1

declare -gA __ADAPTERS_LOADED=()

adapter_load() {
  local kind=$1 name file
  [[ -n ${__ADAPTERS_LOADED[$kind]:-} ]] && return 0
  is_identifier "$kind" || die "$EX_FAIL" "invalid adapter kind '$kind' (bug)"
  name=$(config_get "$kind.adapter")
  is_identifier "$name" || die "$EX_VALIDATION" "invalid setting $kind.adapter = '$name'"
  file="$DEVCTL_ROOT/lib/adapters/$kind/$name.sh"
  [[ -f $file ]] || die "$EX_VALIDATION" "no $kind adapter named '$name' (setting $kind.adapter)"
  # shellcheck source=/dev/null  # path is computed; adapters live in lib/adapters/
  source "$file"
  __ADAPTERS_LOADED[$kind]=$name
}
