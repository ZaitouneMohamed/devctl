#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  ( umask 077; mkdir -p "$DEVCTL_DATA_DIR/registry" )
  source "$REPO_ROOT/lib/services/sites.sh"
  # Database layer replaced: a MySQL server on 3306 with user/password for any database.
  db_server_add() { echo "$1-x"; }
  db_server_start() { :; }
  db_server_get() { local -n __s=$2; __s=([id]=$1 [engine]=mysql [port]=3306); }
  db_database_servers() { :; }
  db_database_create() { echo "CREATE $1 $2" >>"$BATS_TEST_TMPDIR/db.log"; }
  secret_get() { [[ $2 == DB_USERNAME ]] && echo crm || echo S3cretPw; }
}

laravel_site() {
  local p="$BATS_TEST_TMPDIR/crm"
  mkdir -p "$p"
  printf '%s\n' 'APP_NAME=CRM' 'APP_KEY=' 'APP_URL=http://localhost' 'DB_CONNECTION=pgsql' '# DB_HOST=127.0.0.1' >"$p/.env.example"
  site__save crm name=crm category=elden path="$p" domain=crm.test kind=laravel tls=on
}

@test "engine is guessed from the project" {
  laravel_site
  [ "$(site__guess_engine "$BATS_TEST_TMPDIR/crm" laravel)" = postgres ]
  mkdir -p "$BATS_TEST_TMPDIR/sp"
  echo '<artifactId>mysql-connector-j</artifactId>' >"$BATS_TEST_TMPDIR/sp/pom.xml"
  [ "$(site__guess_engine "$BATS_TEST_TMPDIR/sp" proxy)" = mysql ]
  echo '<artifactId>spring-boot-starter-web</artifactId>' >"$BATS_TEST_TMPDIR/sp/pom.xml"
  [ "$(site__guess_engine "$BATS_TEST_TMPDIR/sp" proxy)" = none ]
}

@test "Laravel attach: .env created from .env.example, connection written, 0600, registry updated" {
  laravel_site
  run site_db_attach crm postgres
  [ "$status" -eq 0 ]
  local env="$BATS_TEST_TMPDIR/crm/.env"
  [ "$(stat -c %a "$env")" = 600 ]
  grep -qx 'APP_NAME=CRM' "$env"
  grep -qx 'APP_URL=https://crm.test' "$env"
  grep -qx 'DB_CONNECTION=pgsql' "$env" && grep -qx 'DB_HOST=127.0.0.1' "$env"
  grep -qx 'DB_PORT=3306' "$env" && grep -qx 'DB_DATABASE=crm' "$env" && grep -qx 'DB_PASSWORD=S3cretPw' "$env"
  [[ $output == *"APP_KEY is empty and dependencies are not installed"* ]]
  local -A s=(); site_load crm s
  [ "${s[db_engine]}" = postgres ] && [ "${s[db_server]}" = postgres-x ] && [ "${s[db_name]}" = crm ]
  grep -q 'CREATE postgres-x crm' "$BATS_TEST_TMPDIR/db.log"
}

@test "Laravel attach keeps an existing .env and only changes what it must" {
  laravel_site
  printf '%s\n' 'APP_KEY=base64:abc' 'MAIL_HOST=smtp.example' 'DB_CONNECTION=sqlite' >"$BATS_TEST_TMPDIR/crm/.env"
  site_db_attach crm mysql >/dev/null
  grep -qx 'APP_KEY=base64:abc' "$BATS_TEST_TMPDIR/crm/.env"
  grep -qx 'MAIL_HOST=smtp.example' "$BATS_TEST_TMPDIR/crm/.env"
  grep -qx 'DB_CONNECTION=mysql' "$BATS_TEST_TMPDIR/crm/.env"
}

@test "Laravel SQLite: no server, database file created" {
  laravel_site
  site_db_attach crm sqlite >/dev/null
  [ -f "$BATS_TEST_TMPDIR/crm/database/database.sqlite" ]
  [ ! -e "$BATS_TEST_TMPDIR/db.log" ]
}

@test "Spring attach: devctl.env (0600), git-excluded" {
  local p="$BATS_TEST_TMPDIR/api"
  mkdir -p "$p/.git/info"
  site__save api name=api category=elden path="$p" domain=api.test kind=proxy tls=on app_port=8100
  site_db_attach api mysql >/dev/null
  grep -qx 'SPRING_DATASOURCE_URL=jdbc:mysql://127.0.0.1:3306/api' "$p/devctl.env"
  [ "$(stat -c %a "$p/devctl.env")" = 600 ]
  grep -qx devctl.env "$p/.git/info/exclude"
}

@test "engine must suit the kind" {
  laravel_site
  run site_db_attach crm mongodb
  [ "$status" -eq 2 ]
  site__save web name=web category=elden path=/x domain=web.test kind=static tls=on
  run site_db_attach web mysql
  [ "$status" -eq 2 ]
}

@test "fill: import needs a file; migrate needs dependencies; none does nothing" {
  laravel_site
  site__set crm db_name crm; site__set crm db_server mysql-x
  run site_db_fill crm import
  [ "$status" -eq 4 ]
  run site_db_fill crm migrate
  [ "$status" -eq 7 ] && [[ $output == *"composer install"* ]]
  run site_db_fill crm none
  [ "$status" -eq 0 ]
}

@test "questions without a terminal: guessed engine, migrations" {
  laravel_site
  router__load_command site
  site__db_questions crm "" "" "" </dev/null
  [ "$SITE_DB_ENGINE" = postgres ] && [ "$SITE_DB_FILL" = migrate ]
  site__db_questions crm auto none "" </dev/null
  [ "$SITE_DB_ENGINE" = postgres ] && [ "$SITE_DB_FILL" = none ]
  run site__db_questions crm mysql import "" </dev/null
  [ "$status" -eq 2 ] && [[ $output == *"--file"* ]]
}

@test "CLI: clone plans the database step; site db validates --fill" {
  run devctl --dry-run --yes site clone me/crm --category elden --db auto --fill migrate
  [[ $output == *"database: auto (fill: migrate)"* ]]
  run devctl site clone me/crm --category elden --fill maybe
  [ "$status" -eq 2 ]
}

@test "engine guess in a fresh clone (no .env yet) does not crash; .env wins over .env.example" {
  local p="$BATS_TEST_TMPDIR/fresh"
  mkdir -p "$p"
  printf 'DB_CONNECTION=sqlite\n' >"$p/.env.example"
  [ "$(site__guess_engine "$p" laravel)" = sqlite ]
  printf 'DB_CONNECTION="pgsql"\r\n' >"$p/.env"
  [ "$(site__guess_engine "$p" laravel)" = postgres ]
  rm "$p/.env" "$p/.env.example"
  [ "$(site__guess_engine "$p" laravel)" = mysql ]
}

@test "attach an EXISTING database: same database and user, nothing created" {
  laravel_site
  db_database_resolve() { [[ $1 == domi_api ]] && echo mysql-8-4 || die "$EX_NOTFOUND" "no database named '$1'"; }
  db_server_get() { local -n __s=$2; __s=([id]=$1 [engine]=mysql [port]=3306); }
  secret_get() { [[ $2 == DB_USERNAME ]] && echo domi_api || echo SharedPw; }
  run site_db_attach crm "" domi_api
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/db.log" ]                          # no CREATE
  grep -qx 'DB_DATABASE=domi_api' "$BATS_TEST_TMPDIR/crm/.env"
  grep -qx 'DB_USERNAME=domi_api' "$BATS_TEST_TMPDIR/crm/.env"
  grep -qx 'DB_PASSWORD=SharedPw' "$BATS_TEST_TMPDIR/crm/.env"
  local -A s=(); site_load crm s
  [ "${s[db_name]}" = domi_api ] && [ "${s[db_server]}" = mysql-8-4 ] && [ "${s[db_engine]}" = mysql ]
  # through the real command (strict mode stops at the first error, as in daily use)
  run devctl site db crm --use nope --fill none
  [ "$status" -eq 4 ] && [[ $output == *"no database named 'nope'"* ]]
}

@test "existing database: fill defaults to leave as is; kind must match its engine" {
  laravel_site
  router__load_command site
  site__existing_db() { echo "mysql-8-4 mysql"; }
  site__db_questions crm "" "" "" domi_api </dev/null
  [ "$SITE_DB_FILL" = none ] && [ "$SITE_DB_ENGINE" = mysql ]
  site__existing_db() { echo "mongodb-8-0 mongodb"; }
  run site__db_questions crm "" "" "" logs </dev/null
  [ "$status" -eq 2 ]
}

@test "template with an existing database: Laravel skips migrations, Spring never alters the schema" {
  local -A tpl=()
  site__template_load laravel-blade tpl
  local p="$BATS_TEST_TMPDIR/blog"; mkdir -p "$p"; : >"$p/.env"
  run_change() { echo "RUN $*"; }
  SITE_EXISTING_DB=1 run tpl_configure "$p" blog mysql 3306 domi_api domi_api Pw 
  [[ $output == *"migrations not run"* && $output != *"artisan migrate"* ]]
  site__template_load spring-boot tpl
  mkdir -p "$BATS_TEST_TMPDIR/api"
  SITE_EXISTING_DB=1 tpl_configure "$BATS_TEST_TMPDIR/api" api mysql 3306 domi_api domi_api Pw
  grep -qx 'SPRING_JPA_HIBERNATE_DDL_AUTO=none' "$BATS_TEST_TMPDIR/api/devctl.env"
}

@test "CLI: --use-db validation" {
  run devctl site create x3 --template laravel-blade --category elden --use-db nope
  [ "$status" -eq 4 ] && [[ $output != *"unexpected failure"* ]]
  run devctl site create x3 --template laravel-blade --category elden --use-db shop --db mysql
  [ "$status" -eq 2 ] || [ "$status" -eq 4 ]
  run devctl site clone me/x --category elden --use-db shop --db mysql
  [ "$status" -eq 2 ]
}

@test "database list says which sites use each database (shared ones too)" {
  db__registry_init() { mkdir -p "$DEVCTL_DATA_DIR/registry"; touch "$DB_DATABASES_FILE"; }
  db__registry_init
  printf 'domi_api\tmysql-8-4\tdomi_api\t2026-11-11\n' >>"$DB_DATABASES_FILE"
  site__save domi-api name=domi-api category=elden path=/a domain=domi-api.test kind=laravel tls=on db_server=mysql-8-4 db_name=domi_api
  site__save panel name=panel category=elden path=/b domain=panel.test kind=laravel tls=on db_server=mysql-8-4 db_name=domi_api
  run devctl --json db list --databases
  echo "$output" | jq -e '.[0].sites == ["domi-api", "panel"]'
  run devctl --json site list
  echo "$output" | jq -e '.[] | select(.name == "panel") | .db_engine == " · domi_api" or (.db_engine | endswith("domi_api"))'
}

@test "drivers: drop removes the database and its user" {
  ce_exec() { cat >"$BATS_TEST_TMPDIR/sql"; }
  source "$REPO_ROOT/templates/engines/mysql/driver.sh"
  mysql_drop devctl-mysql-8-4 crm crm
  grep -qx 'DROP DATABASE IF EXISTS `crm`;' "$BATS_TEST_TMPDIR/sql"
  grep -qx "DROP USER IF EXISTS 'crm'@'%';" "$BATS_TEST_TMPDIR/sql"
  source "$REPO_ROOT/templates/engines/postgres/driver.sh"
  postgres_drop devctl-postgres-18 crm crm
  grep -qx 'DROP DATABASE IF EXISTS "crm" WITH (FORCE);' "$BATS_TEST_TMPDIR/sql"
  grep -qx 'DROP ROLE IF EXISTS "crm";' "$BATS_TEST_TMPDIR/sql"
}

@test "db_database_sites lists the sites using a database" {
  site__save a name=a category=elden path=/a domain=a.test kind=laravel tls=on db_server=mysql-8-4 db_name=shared
  site__save b name=b category=elden path=/b domain=b.test kind=laravel tls=on db_server=mysql-8-4 db_name=shared
  site__save c name=c category=elden path=/c domain=c.test kind=laravel tls=on db_server=postgres-18 db_name=shared
  [ "$(db_database_sites mysql-8-4 shared | paste -sd, -)" = a,b ]
  [ "$(db_database_sites postgres-18 shared)" = c ]
  [ -z "$(db_database_sites mysql-8-4 other)" ]
}

@test "CLI: site delete --with-db plans the drop; a shared database is refused and kept" {
  printf 'shop\tmysql-8-4\tshop\t2026-11-05\n' >"$DEVCTL_DATA_DIR/registry/databases.tsv"
  site__save shop name=shop category=personal path="$BATS_TEST_TMPDIR/shop" domain=shop.test kind=laravel tls=on db_engine=mysql db_server=mysql-8-4 db_name=shop
  run devctl site delete
  [ "$status" -eq 2 ]
  run devctl site delete shop --maybe
  [ "$status" -eq 2 ]
  run devctl --dry-run site delete shop --with-db
  [[ $output == *"DELETED: the database shop on mysql-8-4"* ]]
  site__save panel name=panel category=elden path=/p domain=panel.test kind=laravel tls=on db_engine=mysql db_server=mysql-8-4 db_name=shop
  run devctl --dry-run site delete shop --with-db
  [ "$status" -eq 5 ] && [[ $output == *"also used by panel"* ]]
  run devctl --dry-run site delete shop
  [[ $output == *"kept: the folder"*"database shop on mysql-8-4 (also used by panel)"* ]]
  run devctl db drop shop --confirm=shop
  [ "$status" -eq 5 ] && [[ $output == *"used by panel, shop"* || $output == *"used by shop, panel"* ]]
}
