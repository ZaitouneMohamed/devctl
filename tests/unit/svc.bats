#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  ( umask 077; mkdir -p "$DEVCTL_DATA_DIR/data" )
  source "$REPO_ROOT/lib/services/dbservers.sh"
  ss() { :; }
}

@test "services and databases are listed separately" {
  [ "$(dbe_engines service | paste -sd' ')" = "elasticsearch kafka mailpit meilisearch rabbitmq rustfs" ]
  ! dbe_engines | grep -qx mailpit
  run devctl db engines
  [[ $output != *mailpit* ]]
}

@test "extra ports are allocated once and fill their placeholders" {
  id=$(db_server_add mailpit)
  [ "$(db_server_port "$id")" = 1025 ] && [ "$(db_server_port "$id" ui)" = 8025 ]
  f=$(db_server_render "$id")
  grep -q '"127.0.0.1:1025:1025", "127.0.0.1:8025:8025"' "$f"
  ! grep -q '{{' "$f"
}

@test "busy extra port is refused like the main port" {
  ss() { [[ $* == *":8025"* ]] && echo LISTEN; }
  run db_server_add mailpit
  [ "$status" -eq 5 ]
}

@test "several generated secrets plus fixed settings" {
  id=$(db_server_add rustfs)
  grep -qE '^RUSTFS_ACCESS_KEY=[A-Za-z0-9]{32}$' "$(db_server_secrets "$id")"
  grep -qE '^RUSTFS_SECRET_KEY=[A-Za-z0-9]{32}$' "$(db_server_secrets "$id")"
  id=$(db_server_add rabbitmq)
  grep -qx 'RABBITMQ_DEFAULT_USER=devctl' "$(db_server_secrets "$id")"
}

@test "services that would not own their data folder run as your UID" {
  local e
  for e in rustfs kafka; do
    id=$(db_server_add "$e")
    grep -q "user: \"$(id -u):$(id -g)\"" "$(db_server_render "$id")"
  done
  id=$(db_server_add elasticsearch)
  grep -q "user: \"$(id -u):0\"" "$(db_server_render "$id")"
}

@test "every service compose file is valid YAML bound to 127.0.0.1" {
  local e f
  for e in $(dbe_engines service); do
    f=$(db_server_render "$(db_server_add "$e" "" --any-port)")
    python3 -I -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f"
    ! grep '^ *ports:' "$f" | grep -E '"[0-9]+:[0-9]+"'   # every published port has 127.0.0.1:
  done
}

@test "CLI: list, unknown service, info before setup, hints hide secrets unless asked" {
  run devctl svc
  [[ $output == *"not set up"* ]]
  run devctl svc start nope
  [ "$status" -eq 4 ]
  run devctl svc info meilisearch
  [ "$status" -eq 7 ]
  id=$(db_server_add meilisearch)
  run devctl svc info meilisearch
  [[ $output == *"MEILISEARCH_HOST=http://127.0.0.1:7700"* && $output == *"<MEILI_MASTER_KEY>"* ]]
  run devctl svc info meilisearch --show-secrets
  [[ $output != *"<MEILI_MASTER_KEY>"* ]]
}

@test "a fresh install (no registry yet) lists services instead of crashing" {
  run devctl svc
  [ "$status" -eq 0 ]
  [[ $output == *"mailpit"*"not set up"* ]]
  run devctl --json svc
  echo "$output" | jq -e 'length == 6'
}

@test "svc info --json: connection hint and web UI address" {
  db_server_add mailpit >/dev/null
  run devctl --json svc info mailpit
  echo "$output" | jq -e '.ui == "https://mail.test" and .port == 1025 and (.connect | contains("MAIL_PORT=1025"))'
  db_server_add rabbitmq >/dev/null
  run devctl --json svc info rabbitmq
  echo "$output" | jq -e '.ui == "http://127.0.0.1:15672"'
}
