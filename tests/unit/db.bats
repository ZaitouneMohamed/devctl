#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  ( umask 077; mkdir -p "$DEVCTL_DATA_DIR/data" )
  source "$REPO_ROOT/lib/services/dbservers.sh"
  ss() { :; }                       # nothing listens anywhere
}

@test "every engine template is complete and its compose template has all placeholders" {
  local engine
  local -A conf=()
  while IFS= read -r engine; do
    dbe_load "$engine" conf
    [[ ${conf[kind]} == server || ${conf[kind]} == file ]]
    if [[ ${conf[kind]} == server ]]; then
      kv_require conf "$engine" image container_port default_host_port
      grep -q '127.0.0.1:{{PORT}}:' "$DB_ENGINES_DIR/$engine/compose.yaml.tmpl"
      grep -q 'devctl.managed: "true"' "$DB_ENGINES_DIR/$engine/compose.yaml.tmpl"
      grep -q 'restart: "on-failure:3"' "$DB_ENGINES_DIR/$engine/compose.yaml.tmpl"
      grep -q 'max-size' "$DB_ENGINES_DIR/$engine/compose.yaml.tmpl"
    fi
    bash -n "$DB_ENGINES_DIR/$engine/driver.sh"
  done < <(dbe_engines)
  [ "$(dbe_engines | wc -l)" -eq 7 ]
}

@test "add: registers once, fixed port, private secrets, data folder 0711" {
  run db_server_add mysql
  [ "$output" = mysql-8-4 ]
  db_server_add mysql >/dev/null          # idempotent
  [ "$(wc -l <"$DB_SERVERS_FILE")" -eq 1 ]
  local -A srv=()
  db_server_get mysql-8-4 srv
  [ "${srv[port]}" = 3306 ] && [ "${srv[image]}" = mysql:8.4 ]
  [ "$(stat -c %a "$(db_server_secrets mysql-8-4)")" = 600 ]
  grep -qE '^MYSQL_ROOT_PASSWORD=[A-Za-z0-9]{32}$' "$(db_server_secrets mysql-8-4)"
  [ "$(stat -c %a "$DB_DATA_DIR/mysql-8-4")" = 711 ]
}

@test "add: busy default port is refused unless --any-port; ports are never reused" {
  ss() { [[ $* == *":3306"* ]] && echo "LISTEN 0 0 127.0.0.1:3306"; }
  run db_server_add mysql
  [ "$status" -eq 5 ]
  [[ $output == *"devctl db legacy-remove"* ]]
  [ "$(db_server_add mysql 8.4 --any-port)" = mysql-8-4 ]
  local -A srv=()
  db_server_get mysql-8-4 srv
  [ "${srv[port]}" = 3307 ]
  db_server_add mysql 9.7 --any-port >/dev/null
  db_server_get mysql-9-7 srv
  [ "${srv[port]}" = 3308 ]               # 3307 stays reserved
}

@test "add: unknown version / engine / sqlite server" {
  run db_server_add mysql 5.7
  [ "$status" -eq 3 ]
  run db_server_add oracle
  [ "$status" -eq 4 ]
  run db_server_add sqlite
  [ "$status" -eq 2 ]
}

@test "redis: no data folder, no secrets" {
  db_server_add redis >/dev/null
  [ ! -e "$DB_DATA_DIR/redis-8-8" ]
  [ ! -e "$(db_server_secrets redis-8-8)" ]
}

@test "render: placeholders filled, prefix applied, postgres mounts its data folder" {
  db_server_add postgres >/dev/null
  local file
  file=$(db_server_render postgres-18)
  ! grep -q '{{' "$file"
  grep -q 'container_name: "devctl-postgres-18"' "$file"
  grep -q "\"$DB_DATA_DIR/postgres-18:/var/lib/postgresql:Z\"" "$file"
  grep -q '"127.0.0.1:5432:5432"' "$file"
  DEVCTL_CFG_ENGINE_NAME_PREFIX=devctl-x config_load
  grep -q 'container_name: "devctl-x-postgres-18"' "$(db_server_render postgres-18)"
}

@test "database names" {
  db_name_valid shop && db_name_valid shop_v2 && db_name_valid "$(printf 'a%.0s' {1..32})"
  ! db_name_valid Shop && ! db_name_valid 2shop && ! db_name_valid my-shop && ! db_name_valid "a'b" && ! db_name_valid "$(printf 'a%.0s' {1..33})"
}

@test "resolve: unknown, single, ambiguous" {
  db__registry_init
  printf 'shop\tmysql-8-4\tshop\t2026-11-05\n' >>"$DB_DATABASES_FILE"
  [ "$(db_database_resolve shop)" = mysql-8-4 ]
  printf 'shop\tpostgres-18\tshop\t2026-11-05\n' >>"$DB_DATABASES_FILE"
  run db_database_resolve shop
  [ "$status" -eq 2 ] && [[ $output == *"add --server"* ]]
  [ "$(db_database_resolve shop postgres-18)" = postgres-18 ]
  run db_database_resolve nope
  [ "$status" -eq 4 ]
}

@test "secrets: generated passwords, 0600 files, bad entries refused" {
  local p
  p=$(secret_generate)
  [[ $p =~ ^[A-Za-z0-9]{32}$ ]]
  [ "$(secret_generate)" != "$p" ]
  secret_write "$DEVCTL_SECRETS_DIR/t.env" "A=1" "B_C=x.y"
  [ "$(secret_get "$DEVCTL_SECRETS_DIR/t.env" B_C)" = x.y ]
  run secret_write "$DEVCTL_SECRETS_DIR/t.env" 'A=$(rm -rf ~)'
  [ "$status" -eq 1 ]
  [ "$(secret_get "$DEVCTL_SECRETS_DIR/t.env" A)" = 1 ]   # unchanged
}

@test "memory guard asks only below the limit" {
  guard__meminfo() { echo "2000000 24000000"; }      # ~8%
  run guard_memory "MySQL" </dev/null
  [ "$status" -eq 7 ] && [[ $output == *"RAM available"* ]]
  guard__meminfo() { echo "16000000 24000000"; }
  guard_memory "MySQL"
}

@test "drivers: SQL text for MySQL user creation, nothing secret on the command line" {
  dbe__driver_load mysql
  ce_exec() { printf '%s\n' "ARGS: $*"; cat; }
  run mysql_create devctl-mysql-8-4 shop shop Secret123
  [[ $output == *"CREATE USER IF NOT EXISTS 'shop'@'%' IDENTIFIED BY 'Secret123'"* ]]
  [[ $output == *"GRANT ALL PRIVILEGES ON \`shop\`.* TO 'shop'@'%'"* ]]
  [[ $(grep '^ARGS:' <<<"$output") != *Secret123* ]]
}

@test "CLI: db engines, empty list, dry-run create, sqlite and redis refused" {
  run devctl db engines
  [[ $output == *"postgres  PostgreSQL + pgvector"* ]]
  run devctl db
  [[ $output == *"no servers yet"* ]]
  run devctl --dry-run db create shop --engine postgres
  [ "$status" -eq 0 ] && [[ $output == *"create database 'shop'"* ]]
  [ ! -e "$HOME/.local/share/devctl/registry/servers.tsv" ] || [ ! -s "$HOME/.local/share/devctl/registry/servers.tsv" ]
  run devctl db create shop --engine sqlite
  [ "$status" -eq 2 ]
  run devctl db create shop --engine redis
  [ "$status" -eq 2 ]
}

@test "legacy-remove needs the typed word and shows everything it deletes" {
  mkdir -p "$HOME/Desktop/projects/databases"
  touch "$HOME/Desktop/projects/databases/compose.yaml" "$HOME/Desktop/projects/databases/compose.yam"
  run devctl --yes db legacy-remove </dev/null
  [ "$status" -eq 7 ]
  [ -e "$HOME/Desktop/projects/databases/compose.yaml" ]
  run devctl --dry-run db legacy-remove
  [[ $output == *"down --volumes"* && $output == *"rm -f -- $HOME/Desktop/projects/databases/compose.yam"* ]]
}

@test "JSON for the dashboard: database list" {
  run devctl --json db list --databases
  [ "$output" = "[]" ]
  db__registry_init
  printf 'shop\tmysql-8-4\tshop\t2026-11-05\n' >>"$DB_DATABASES_FILE"
  run devctl --json db list --databases
  echo "$output" | jq -e '.[0].name == "shop" and .[0].server == "mysql-8-4"'
}
