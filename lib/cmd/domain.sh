# shellcheck shell=bash
# summary: Local domain names (managed block in /etc/hosts)

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action domain.apply
adapter_load dns

cmd_domain() { cmd_domain_list "$@"; }

cmd_domain_list() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl domain list"
  local name
  local -a names=() live=()
  mapfile -t names < <(dns_names)
  mapfile -t live < <(dns_live)
  if ((DEVCTL_JSON)); then
    local -a rows=()
    for name in "${names[@]}"; do
      rows+=("$name" "$(is_in_list "$name" "${live[@]}" && echo yes || echo no)" "$(dns_resolves "$name" && echo yes || echo no)")
    done
    jq -n --argjson r "$(json_array "${rows[@]}")" '[range(0; $r | length; 3) as $i | {name: $r[$i], in_hosts: ($r[$i + 1] == "yes"), resolves: ($r[$i + 2] == "yes")}]'
    return 0
  fi
  ((${#names[@]})) || { ui_skip "no local names yet"; return 0; }
  {
    printf 'NAME\tIN /etc/hosts\tRESOLVES HERE\n'
    for name in "${names[@]}"; do
      printf '%s\t%s\t%s\n' "$name" "$(is_in_list "$name" "${live[@]}" && echo yes || echo 'no (devctl domain apply)')" "$(dns_resolves "$name" && echo yes || echo no)"
    done
  } | ui_table
}

cmd_domain_apply() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl domain apply"
  dns_apply
  ((DEVCTL_DRY_RUN)) || ui_ok "/etc/hosts is up to date"
}

help_domain() {
  cat <<'HELP'
Usage: devctl domain [list]   local names, whether they are in /etc/hosts and resolve here
       devctl domain apply    bring devctl's block in /etc/hosts up to date (sudo password)

Names are added and removed by `devctl site …` and `devctl dashboard`. Only the block
between "# >>> devctl managed block" and "# <<< devctl managed block" is ever changed;
a backup is kept as /etc/hosts.devctl.bak.
HELP
}
