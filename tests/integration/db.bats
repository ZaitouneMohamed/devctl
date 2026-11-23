#!/usr/bin/env bats
# Integration tests against the real Docker daemon (make itest). Everything is isolated:
# temporary HOME (registry, secrets, data), containers named devctl-itest-*, ports chosen
# automatically. Teardown removes only what these tests created.
bats_require_minimum_version 1.5.0

setup_file() {
  systemctl is-active --quiet docker.service || skip "Docker is not running"
  export ITEST_HOME="$BATS_FILE_TMPDIR/home"
  mkdir -p "$ITEST_HOME"
  export HOME="$ITEST_HOME" DEVCTL_CFG_ENGINE_NAME_PREFIX=devctl-itest
  export PATH="$BATS_TEST_DIRNAME/../../bin:$PATH"
  devctl --yes init >/dev/null 2>&1 || true   # folders + data dir (helper step needs a terminal)
}

teardown_file() {
  local id data
  for id in mysql-8-4 postgres-18 redis-8-8; do
    devctl db stop "$id" --force >/dev/null 2>&1 || true
  done
  # Data files belong to the containers' users: delete them from inside a container.
  data="$ITEST_HOME/.local/share/devctl/data"
  [[ -d $data ]] && docker run --rm -v "$data:/data:z" mysql:8.4 sh -c 'rm -rf /data/*' >/dev/null 2>&1 || true
  docker network rm devctl >/dev/null 2>&1 || true   # only if nothing else uses it
}

@test "mysql: create, use as the project user, export, import into another database" {
  run devctl db add mysql --any-port
  [ "$status" -eq 0 ]
  run devctl db create itest_app --engine mysql
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(docker inspect -f '{{.State.Health.Status}}' devctl-itest-mysql-8-4)" = healthy ]
  # published on loopback only
  [[ $(docker port devctl-itest-mysql-8-4 3306) == 127.0.0.1:* ]]
  local pw
  pw=$(devctl --json db creds itest_app | jq -r .password)
  [ ${#pw} -eq 32 ]
  MYSQL_PWD=$pw docker exec -i -e MYSQL_PWD devctl-itest-mysql-8-4 mysql -uitest_app itest_app \
    -e "CREATE TABLE t (id INT PRIMARY KEY, name VARCHAR(20)); INSERT INTO t VALUES (1, 'devctl');"
  # the project user cannot see other databases
  run bash -c "MYSQL_PWD=$pw docker exec -i -e MYSQL_PWD devctl-itest-mysql-8-4 mysql -uitest_app -e 'CREATE DATABASE other'"
  [ "$status" -ne 0 ]
  run devctl db export itest_app "$BATS_FILE_TMPDIR/app.sql.gz"
  [ "$status" -eq 0 ] && [ -s "$BATS_FILE_TMPDIR/app.sql.gz" ]
  devctl db create itest_copy --engine mysql
  run devctl db import itest_copy "$BATS_FILE_TMPDIR/app.sql.gz"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local pw2
  pw2=$(devctl --json db creds itest_copy | jq -r .password)
  run bash -c "MYSQL_PWD=$pw2 docker exec -i -e MYSQL_PWD devctl-itest-mysql-8-4 mysql -N -uitest_copy itest_copy -e 'SELECT name FROM t'"
  [ "$output" = devctl ]
  # importing again into a non-empty database needs the typed name
  run devctl db import itest_copy "$BATS_FILE_TMPDIR/app.sql.gz" </dev/null
  [ "$status" -eq 7 ]
  # data really lives in devctl's data folder (bind mount, not a Docker volume)
  [ "$(docker inspect -f '{{range .Mounts}}{{.Source}}{{end}}' devctl-itest-mysql-8-4)" = "$HOME/.local/share/devctl/data/mysql-8-4" ]
}

@test "postgres: database owned by its user, pgvector enabled, export/import" {
  run devctl db create itest_ai --engine postgres --any-port
  [ "$status" -eq 2 ]   # --any-port belongs to db add
  devctl db add postgres --any-port
  run devctl db create itest_ai --engine postgres
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local pw
  pw=$(devctl --json db creds itest_ai | jq -r .password)
  run bash -c "PGPASSWORD=$pw docker exec -i -e PGPASSWORD devctl-itest-postgres-18 psql -h 127.0.0.1 -U itest_ai -d itest_ai -qAt -c \"CREATE TABLE items (id int, embedding vector(3)); INSERT INTO items VALUES (1, '[1,2,3]'); SELECT extversion IS NOT NULL FROM pg_extension WHERE extname = 'vector';\""
  [ "$output" = t ] || { echo "$output"; return 1; }
  run bash -c "PGPASSWORD=$pw docker exec -i -e PGPASSWORD devctl-itest-postgres-18 psql -h 127.0.0.1 -U itest_ai -d postgres -c 'CREATE DATABASE nope'"
  [ "$status" -ne 0 ]
  devctl db export itest_ai "$BATS_FILE_TMPDIR/ai.dump.gz"
  devctl db create itest_ai2 --engine postgres
  run devctl db import itest_ai2 "$BATS_FILE_TMPDIR/ai.dump.gz"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run docker exec devctl-itest-postgres-18 psql -U postgres -d itest_ai2 -qAt -c 'SELECT embedding FROM items'
  [ "$output" = '[1,2,3]' ]
  # data in <mount>/18/docker, no anonymous volumes
  [ "$(docker inspect -f '{{len .Mounts}}' devctl-itest-postgres-18)" = 1 ]
  docker exec devctl-itest-postgres-18 test -f /var/lib/postgresql/18/docker/PG_VERSION
  [ "$(docker inspect -f '{{range .Mounts}}{{.Source}}{{end}}' devctl-itest-postgres-18)" = "$HOME/.local/share/devctl/data/postgres-18" ]
}

@test "redis: cache server answers, nothing persisted" {
  devctl db add redis --any-port
  devctl db start redis-8-8
  [ "$(docker exec devctl-itest-redis-8-8 redis-cli ping)" = PONG ]
  [ "$(docker exec devctl-itest-redis-8-8 redis-cli config get save | tail -1)" = "" ]
  [ ! -e "$HOME/.local/share/devctl/data/redis-8-8" ]
}

@test "list shows the servers running with their fixed ports" {
  run devctl --json db list
  echo "$output" | jq -e 'length == 3 and all(.[]; .state == "running")'
}

@test "refcount: stop refuses while in use, release stops at zero" {
  export DEVCTL_ROOT="$BATS_TEST_DIRNAME/../.."
  run bash -c '
    DEVCTL_ROOT=$1; source "$DEVCTL_ROOT/lib/core/bootstrap.sh"; config_load
    source "$DEVCTL_ROOT/lib/services/dbservers.sh"
    db_server_acquire redis-8-8 itest && db_refcount redis-8-8' _ "$DEVCTL_ROOT"
  [ "$output" = 1 ]
  run devctl db stop redis-8-8
  [ "$status" -eq 5 ]
  run bash -c '
    DEVCTL_ROOT=$1; source "$DEVCTL_ROOT/lib/core/bootstrap.sh"; config_load
    source "$DEVCTL_ROOT/lib/services/dbservers.sh"
    db_server_release redis-8-8 itest >/dev/null 2>&1; db_server_state redis-8-8' _ "$DEVCTL_ROOT"
  [ "$output" = stopped ] || { echo "state after release: $output"; return 1; }
}
