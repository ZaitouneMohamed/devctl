# shellcheck shell=bash
# summary: Show devctl settings and where each value comes from

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

cmd_config() {
  cmd_config_show "$@"
}

cmd_config_show() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl config show"
  local key
  local -a keys=()
  mapfile -t keys < <(config_keys)

  if ((DEVCTL_JSON)); then
    local -a triples=()
    for key in "${keys[@]}"; do
      triples+=("$key" "${DEVCTL_CFG[$key]}" "$(config_origin "$key")")
    done
    jq -n --argjson t "$(json_array "${triples[@]}")" \
      '[range(0; $t | length; 3) as $i | {key: $t[$i], value: $t[$i + 1], from: $t[$i + 2]}]'
    return 0
  fi

  {
    printf 'SETTING\tVALUE\tFROM\n'
    for key in "${keys[@]}"; do
      printf '%s\t%s\t%s\n' "$key" "${DEVCTL_CFG[$key]:-(empty)}" "$(config_origin "$key")"
    done
  } | ui_table
}

cmd_config_get() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl config get <setting>"
  [[ -n ${__CFG_ORIGIN[$1]:-} ]] || die "$EX_NOTFOUND" "unknown setting '$1' (see: devctl config show)"
  config_get "$1"
}

cmd_config_path() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl config path"
  printf '%s\n' "$DEVCTL_USER_CONFIG"
  [[ -e $DEVCTL_USER_CONFIG ]] || ui_note "file does not exist yet; defaults are used"
}

help_config() {
  cat <<'EOF'
Usage: devctl config [show]        list every setting, its value and where it comes from
       devctl config get <setting> print one value
       devctl config path          print the path of your config file

Settings are layered (later wins):
  1. defaults      share/defaults.conf in the devctl repo (documents every setting)
  2. user          ~/.config/devctl/devctl.conf  (same "key = value" syntax, mode 600)
  3. env           DEVCTL_CFG_<KEY>, e.g. DEVCTL_CFG_DOMAIN_SUFFIX=test
  4. flag          command-line options such as --color=never

Values are literal text: no variables, no command substitution.
EOF
}

complete_config() {
  [[ $1 == args && $2 == get && $3 == 1 ]] && config_keys
  return 0
}
