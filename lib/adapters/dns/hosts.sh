# shellcheck shell=bash
# Local names adapter: a managed block in /etc/hosts (ADR-0004).
# Desired state = ~/.local/share/devctl/hosts (one name per line); the helper's hosts-apply
# rewrites only devctl's block. Swappable for a resolver-based adapter later.

# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

DNS_LIST_FILE="$DEVCTL_DATA_DIR/hosts"

dns_names() { [[ -f $DNS_LIST_FILE ]] && grep -v '^$' -- "$DNS_LIST_FILE"; return 0; }

# dns_resolves NAME — the name currently points at this laptop.
dns_resolves() { getent ahosts "$1" 2>/dev/null | grep -qE '^(127\.0\.0\.1|::1) '; }

# dns_live NAMES — names present in devctl's block of /etc/hosts.
dns_live() {
  awk '/^# >>> devctl managed block/ {b=1; next} /^# <<< devctl managed block/ {b=0} b && $1 == "127.0.0.1" {print $2}' /etc/hosts
}

dns__write() { # NAME... — replace the list (sorted, unique)
  [[ $DNS_LIST_FILE == "$HOME/.local/share/devctl/hosts" ]] ||
    die "$EX_PRECONDITION" "local names need the default data folder (~/.local/share); unset XDG_DATA_HOME"
  ensure_private_dir "${DNS_LIST_FILE%/*}"
  local tmp
  tmp=$(mktemp "${DNS_LIST_FILE%/*}/.hosts.XXXXXX")
  (($#)) && printf '%s\n' "$@" | LC_ALL=C sort -u >"$tmp"
  mv -f -- "$tmp" "$DNS_LIST_FILE"
}

dns_add() { # NAME — add to the list (no system change until dns_apply)
  local -a names=()
  mapfile -t names < <(dns_names)
  is_in_list "$1" "${names[@]}" && return 0
  ((DEVCTL_DRY_RUN)) && { ui_plan "add local name $1"; return 0; }
  dns__write "${names[@]}" "$1"
}

dns_remove() {
  local -a names=() keep=()
  local n
  mapfile -t names < <(dns_names)
  is_in_list "$1" "${names[@]}" || return 0
  ((DEVCTL_DRY_RUN)) && { ui_plan "remove local name $1"; return 0; }
  for n in "${names[@]}"; do [[ $n == "$1" ]] || keep+=("$n"); done
  dns__write "${keep[@]}"
}

# dns_apply — make /etc/hosts match the list (helper, sudo password) if it differs.
dns_apply() {
  if [[ "$(dns_names | LC_ALL=C sort -u)" == "$(dns_live | LC_ALL=C sort -u)" ]]; then
    return 0
  fi
  priv_run --desc "Update devctl's block in /etc/hosts" hosts-apply
}
