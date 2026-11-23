# shellcheck shell=bash
# summary: Logs of a site: application, PHP, web server, database

# shellcheck source=lib/services/sites.sh
source "${DEVCTL_ROOT:?}/lib/services/sites.sh"

# Sources:  --app  storage/logs/laravel.log          --php  journal (devctl-php), lines for this site
#           --web  Caddy's journal, requests for this site   --db  the site's database server
# Vite prints in the terminal that runs `devctl site dev`.

logs__web() { # DOMAIN LINES FOLLOW
  local -a opts=(-u caddy.service -o cat --no-pager)
  (($3)) && opts+=(-f) || opts+=(-n 2000)
  journalctl "${opts[@]}" 2>/dev/null |
    jq --unbuffered -R -r --arg host "$1" 'fromjson? | select(.request.host? == $host or (.request.host? // "" | startswith($host + ":")))
      | "\(.ts | strflocaltime("%H:%M:%S")) \(.status // "-") \(.request.method) \(.request.uri) \(.msg | select(. != "handled request") // "")"' 2>/dev/null |
    if (($3)); then cat; else tail -n "$2"; fi
}

logs__php() { # PATH LINES FOLLOW
  local -a opts=(-t devctl-php -o short-iso --no-pager)
  (($3)) && opts+=(-f) || opts+=(-n 2000)
  journalctl "${opts[@]}" 2>/dev/null | grep --line-buffered -F -- "$1" | if (($3)); then cat; else tail -n "$2"; fi
}

logs__app() { # PATH LINES FOLLOW
  local f="$1/storage/logs/laravel.log"
  [[ -f $f ]] || { ui_skip "no application log yet ($f)"; return 0; }
  if (($3)); then tail -n "$2" -F -- "$f"; else tail -n "$2" -- "$f"; fi
}

cmd_logs() {
  local name="" lines=50 follow=0
  local -a parts=()
  while (($#)); do
    case $1 in
      --app | --php | --web | --db) parts+=("${1#--}") ;;
      --vite) die "$EX_USAGE" "Vite prints in the terminal running 'devctl site dev'; dashboard-started Vite logs come with the dashboard's process view" ;;
      -f | --follow) follow=1 ;;
      -n | --lines) lines=${2:-}; shift ;;
      --lines=*) lines=${1#*=} ;;
      -*) die "$EX_USAGE" "usage: devctl logs SITE [--app] [--php] [--web] [--db] [-f] [-n N]" ;;
      *) name=$1 ;;
    esac
    shift
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl logs SITE [--app] [--php] [--web] [--db] [-f] [-n N]"
  require_valid uint "$lines" "--lines"
  local -A s=()
  site_load "$name" s
  ((${#parts[@]})) || parts=(app web)
  ((follow && ${#parts[@]} > 1)) && die "$EX_USAGE" "--follow works with one part at a time (e.g. --web -f)"
  local part
  for part in "${parts[@]}"; do
    ((${#parts[@]} > 1)) && ui_header "── $part"
    case $part in
      app) logs__app "${s[path]}" "$lines" "$follow" ;;
      php) logs__php "${s[path]}" "$lines" "$follow" ;;
      web) logs__web "${s[domain]}" "$lines" "$follow" ;;
      db)
        [[ -n ${s[db_server]:-} ]] || { ui_skip "$name has no database server"; continue; }
        ce_daemon_running || { ui_skip "Docker is not running"; continue; }
        local -a o=(--tail "$lines")
        ((follow)) && o+=(--follow)
        ui_note "shared server ${s[db_server]}: lines may come from other sites"
        ce_logs "$(db_server_container "${s[db_server]}")" "${o[@]}"
        ;;
    esac
  done
}

complete_logs() {
  case $1 in
    flags) printf '%s\n' --app --php --web --db --follow --lines ;;
    args) [[ $3 == 1 || $2 != -* ]] && site_names ;;
  esac
  return 0
}

help_logs() {
  cat <<'HELP'
Usage: devctl logs SITE [--app] [--php] [--web] [--db] [-f] [-n N]
  --app   Laravel's storage/logs/laravel.log       --php  PHP errors for this site (journal)
  --web   requests to https://SITE.test (Caddy)    --db   the site's database server
  default: --app and --web, last 50 lines each; -f follows one part.
HELP
}
