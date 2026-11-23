# shellcheck shell=bash
# summary: Extra services: Mailpit, Meilisearch, Elasticsearch, RustFS (S3), RabbitMQ, Kafka

# shellcheck source=lib/services/dbservers.sh
source "${DEVCTL_ROOT:?}/lib/services/dbservers.sh"

register_action svc.start svc.stop

# A service is an engine template with "category = service" (templates/engines/<name>/).
# One shared instance each, on fixed 127.0.0.1 ports, started only when you ask.

svc__require() { # NAME — die unless NAME is a service template
  local -a names=()
  mapfile -t names < <(dbe_engines service)
  is_in_list "$1" "${names[@]}" || die "$EX_NOTFOUND" "unknown service '$1' (choose: ${names[*]})"
}

svc__id() { # NAME → registered server id, or empty (no registry yet on a fresh install)
  local id engine
  [[ -f $DB_SERVERS_FILE ]] || return 0
  while IFS=$'\t' read -r id engine _; do
    [[ $engine == "$1" ]] && { printf '%s\n' "$id"; return 0; }
  done <"$DB_SERVERS_FILE"
  return 0
}

# svc__hint NAME ID [show] — the connection hint with ports (and secrets only on request).
svc__hint() {
  local -A conf=()
  dbe_load "$1" conf
  local hint=${conf[hint]:-} port owner key value
  hint=${hint//\{\{PORT\}\}/$(db_server_port "$2")}
  hint=${hint//\{\{SUFFIX\}\}/$(config_get domain.suffix)}
  local extra
  [[ -f $DB_PORTS_FILE ]] && while IFS=$'\t' read -r port owner _; do
    [[ $owner == "$2/"* ]] || continue
    extra=${owner#*/}
    hint=${hint//\{\{PORT_${extra^^}\}\}/$port}
  done <"$DB_PORTS_FILE"
  if [[ ${3:-} == show && -f $(db_server_secrets "$2") ]]; then
    while IFS='=' read -r key value; do
      hint=${hint//<$key>/$value}
    done <"$(db_server_secrets "$2")"
  fi
  printf '%s\n' "$hint"
}

cmd_svc() { cmd_svc_list "$@"; }

cmd_svc_list() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl svc list"
  local name id state
  local -a rows=()
  local -A conf=()
  while IFS= read -r name; do
    dbe_load "$name" conf
    id=$(svc__id "$name")
    state="not set up"
    [[ -n $id ]] && state=$(db_server_state "$id")
    rows+=("$name" "${conf[name]}" "${conf[default_major]}" "$state" "$([[ -n $id ]] && svc__hint "$name" "$id" || echo "-")")
  done < <(dbe_engines service)
  if ((DEVCTL_JSON)); then
    jq -n --argjson r "$(json_array "${rows[@]}")" \
      '[range(0; $r | length; 5) as $i | {name: $r[$i], title: $r[$i + 1], version: $r[$i + 2], state: $r[$i + 3], connect: $r[$i + 4]}]'
    return 0
  fi
  {
    printf 'SERVICE\tNAME\tVERSION\tSTATE\n'
    for ((i = 0; i < ${#rows[@]}; i += 5)); do printf '%s\t%s\t%s\t%s\n' "${rows[@]:i:4}"; done
  } | ui_table
}

cmd_svc_start() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl svc start SERVICE"
  svc__require "$1"
  local id
  local -A conf=()
  dbe_load "$1" conf
  id=$(svc__id "$1")
  [[ -n $id ]] || id=$(db_server_add "$1")
  ((DEVCTL_DRY_RUN)) && { ui_plan "start $1"; return 0; }
  db_server_start "$id"
  if [[ -n ${conf[web_name]:-} ]]; then
    # e.g. Mailpit's inbox at https://mail.<suffix>
    adapter_load web
    adapter_load dns
    local domain
    domain="${conf[web_name]}.$(config_get domain.suffix)"
    web_render proxy "${conf[web_name]}" "$domain" on - "$(db_server_port "$id" ui)" -
    dns_add "$domain"
    dns_apply
    web_needs_apply && web_apply
    web_start
  fi
  ui_ok "${conf[name]} is running"
  printf '  %s\n' "$(svc__hint "$1" "$id")"
}

cmd_svc_stop() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl svc stop SERVICE"
  svc__require "$1"
  local id
  id=$(svc__id "$1")
  [[ -n $id ]] || { ui_skip "$1 is not set up"; return 0; }
  db_server_stop "$id"
  ((DEVCTL_DRY_RUN)) || ui_ok "$1 stopped"
}

# info: how to connect (secrets shown only with --show-secrets).
cmd_svc_info() {
  local name="" show=""
  for arg; do
    case $arg in
      --show-secrets) show=show ;;
      -*) die "$EX_USAGE" "usage: devctl svc info SERVICE [--show-secrets]" ;;
      *) name=$arg ;;
    esac
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl svc info SERVICE [--show-secrets]"
  svc__require "$name"
  local id
  id=$(svc__id "$name")
  [[ -n $id ]] || die "$EX_PRECONDITION" "$name is not set up yet: devctl svc start $name"
  if ((DEVCTL_JSON)); then
    local -A conf=()
    dbe_load "$name" conf
    local ui=""
    [[ -n ${conf[web_name]:-} ]] && ui="https://${conf[web_name]}.$(config_get domain.suffix)"
    [[ -z $ui && -n $(db_server_port "$id" ui) ]] && ui="http://127.0.0.1:$(db_server_port "$id" ui)"
    [[ -z $ui && -n $(db_server_port "$id" console) ]] && ui="http://127.0.0.1:$(db_server_port "$id" console)"
    [[ -z $ui && $name == meilisearch ]] && ui="http://127.0.0.1:$(db_server_port "$id")"
    jq -nc --arg connect "$(svc__hint "$name" "$id" "$show")" --arg ui "$ui" --arg port "$(db_server_port "$id")" \
      '{connect: $connect, ui: $ui, port: ($port | tonumber)}'
    return 0
  fi
  [[ -n $show && -t 1 ]] && ui_note "contains secrets: do not paste them into chats, tickets or commits"
  printf '%s\n' "$(svc__hint "$name" "$id" "$show")"
}

cmd_svc_logs() {
  local name="" follow=0
  for arg; do
    case $arg in
      -f | --follow) follow=1 ;;
      -*) die "$EX_USAGE" "usage: devctl svc logs SERVICE [-f]" ;;
      *) name=$arg ;;
    esac
  done
  svc__require "$name"
  local id
  id=$(svc__id "$name")
  if [[ -z $id ]] || ! ce_daemon_running; then die "$EX_PRECONDITION" "$name is not running"; fi
  local -a o=(--tail 100)
  ((follow)) && o+=(--follow)
  ce_logs "$(db_server_container "$id")" "${o[@]}"
}

complete_svc() {
  case $1:$2 in
    args:start | args:stop | args:info | args:logs) [[ $3 == 1 ]] && dbe_engines service ;;
    flags:info) printf '%s\n' --show-secrets ;;
    flags:logs) printf '%s\n' --follow ;;
  esac
  return 0
}

help_svc() {
  cat <<'HELP'
Usage: devctl svc [list]                       services, versions, state
       devctl svc start|stop SERVICE           started only when you ask (memory warning for heavy ones)
       devctl svc info SERVICE [--show-secrets] how to connect (e.g. the lines for Laravel's .env)
       devctl svc logs SERVICE [-f]

Services: mailpit (catches your apps' emails; inbox at https://mail.test), meilisearch,
elasticsearch, rustfs (S3-compatible storage), rabbitmq, kafka. All on 127.0.0.1 only,
fixed ports, data in ~/.local/share/devctl/data (except Mailpit: in memory).
HELP
}
