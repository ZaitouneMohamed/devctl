# shellcheck shell=bash
# summary: What is running and is it healthy: services, sites, databases, disk, memory

# shellcheck source=lib/services/sites.sh
source "${DEVCTL_ROOT:?}/lib/services/sites.sh"

# Health is only checked here and in the dashboard, never in the background (requirements).

st__unit() { systemctl is-active "$1" 2>/dev/null || true; }

# st__http URL — HTTP status code of a quick request (000 = no answer).
st__http() { curl -sk -o /dev/null -m 3 -w '%{http_code}' -- "$1" 2>/dev/null || printf '000'; }

st__site_health() { # NAME → ok | stopped | <code>
  local -A s=()
  site_load "$1" s
  site_running "$1" || { printf 'stopped\n'; return; }
  local code
  code=$(st__http "https://${s[domain]}/")
  case $code in 2?? | 3?? | 401 | 419) printf 'ok (%s)\n' "$code" ;; *) printf 'problem (HTTP %s)\n' "$code" ;; esac
}

st__db_health() { # SERVER → health from the container's healthcheck
  local state h
  state=$(db_server_state "$1")
  [[ $state == running ]] || { printf '%s\n' "$state"; return; }
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' -- "$(db_server_container "$1")" 2>/dev/null || echo unknown)
  printf '%s\n' "$h"
}

st__mem() { awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d%% available (%.1f of %.1f GiB)\n", a*100/t, a/1048576, t/1048576}' /proc/meminfo; }
st__disk() { df -h --output=avail,pcent -- "$HOME" | tail -1 | awk '{sub("%","",$2); printf "%d%% free (%s)\n", 100-$2, $1}'; }

cmd_status() {
  local watch=0
  case ${1:-} in
    "") ;;
    --watch) watch=1 ;;
    *) die "$EX_USAGE" "usage: devctl status [--watch]" ;;
  esac
  if ((watch)); then
    [[ -t 1 ]] || die "$EX_USAGE" "--watch needs a terminal"
    while true; do
      local out
      out=$(status__snapshot 2>&1)
      printf '\e[H\e[2J%s\n\n%s\n' "$out" "$(ui_paint 1 dim "refreshing every 3 s — Ctrl+C to quit")"
      sleep 3
    done
  fi
  status__snapshot
}

status__snapshot() {
  local name id
  local -a sites=() servers=()
  mapfile -t sites < <(site_names)
  mapfile -t servers < <(db_server_ids)
  if ((DEVCTL_JSON)); then
    local -a srows=() drows=()
    for name in "${sites[@]}"; do srows+=("$name" "$(site_domain "$name")" "$(st__site_health "$name")"); done
    for id in "${servers[@]}"; do [[ -n $id ]] && drows+=("$id" "$(st__db_health "$id")" "$(db_refcount "$id")"); done
    jq -n --arg docker "$(st__unit docker.service)" --arg caddy "$(st__unit caddy.service)" --arg php "$(st__unit php-fpm.service)" \
      --arg memory "$(st__mem)" --arg disk "$(st__disk)" \
      --argjson s "$(json_array "${srows[@]}")" --argjson d "$(json_array "${drows[@]}")" \
      '{services: {docker: $docker, caddy: $caddy, php_fpm: $php}, memory: $memory, disk: $disk,
        sites: [range(0; $s | length; 3) as $i | {name: $s[$i], domain: $s[$i + 1], health: $s[$i + 2]}],
        databases: [range(0; $d | length; 3) as $i | {server: $d[$i], health: $d[$i + 1], used_by: ($d[$i + 2] | tonumber)}]}'
    return 0
  fi
  ui_header "Services"
  {
    printf 'Docker\t%s\n' "$(st__unit docker.service)"
    printf 'Caddy (web)\t%s\n' "$(st__unit caddy.service)"
    printf 'PHP-FPM\t%s\n' "$(st__unit php-fpm.service)"
    printf 'Memory\t%s\n' "$(st__mem)"
    printf 'Disk\t%s\n' "$(st__disk)"
  } | ui_table
  printf '\n'
  ui_header "Sites"
  if ((${#sites[@]})); then
    { printf 'SITE\tURL\tHEALTH\n'; for name in "${sites[@]}"; do printf '%s\thttps://%s\t%s\n' "$name" "$(site_domain "$name")" "$(st__site_health "$name")"; done; } | ui_table
  else
    ui_skip "no sites"
  fi
  printf '\n'
  ui_header "Database servers"
  if ((${#servers[@]})) && [[ -n ${servers[0]} ]]; then
    { printf 'SERVER\tHEALTH\tUSED BY\n'; for id in "${servers[@]}"; do printf '%s\t%s\t%s\n' "$id" "$(st__db_health "$id")" "$(db_server_holders "$id" | paste -sd' ' | sed 's/^$/-/')"; done; } | ui_table
  else
    ui_skip "no database servers"
  fi
}

complete_status() { [[ $1 == flags ]] && printf '%s\n' --watch; return 0; }

help_status() {
  cat <<'HELP'
Usage: devctl status            snapshot: services, sites (HTTPS check), databases, memory, disk
       devctl status --watch    refresh every 3 seconds (Ctrl+C to quit)
       devctl --json status     for scripts and the dashboard
HELP
}
