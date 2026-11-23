#!/usr/bin/env bats
# Real Docker, isolated like db.bats: temporary HOME, devctl-itest-* containers, any free ports.
# Uses the service layer directly (not `devctl svc start`) so no web-server/password step runs.
bats_require_minimum_version 1.5.0

setup_file() {
  systemctl is-active --quiet docker.service || skip "Docker is not running"
  export ITEST_HOME="$BATS_FILE_TMPDIR/home"
  mkdir -p "$ITEST_HOME"
  export HOME="$ITEST_HOME" DEVCTL_CFG_ENGINE_NAME_PREFIX=devctl-itest
  export DEVCTL_ROOT="$BATS_TEST_DIRNAME/../.."
}

teardown_file() {
  local id
  for id in mailpit-1-33 meilisearch-1-56 rustfs-1-0-4 rabbitmq-4-4 elasticsearch-9-5-5 kafka-4-4-0; do
    docker rm -f "devctl-itest-$id" >/dev/null 2>&1 || true
  done
  local data="$ITEST_HOME/.local/share/devctl/data"
  [[ -d $data ]] && docker run --rm -v "$data:/data:z" mysql:8.4 sh -c 'rm -rf /data/*' >/dev/null 2>&1 || true
}

# up SERVICE — register (any free ports) and start; prints the server id.
up() {
  bash -c 'source "$DEVCTL_ROOT/lib/core/bootstrap.sh"; config_load; ensure_private_dir "$DEVCTL_DATA_DIR/data"
    source "$DEVCTL_ROOT/lib/services/dbservers.sh"; guard_memory() { :; }
    id=$(db_server_add "$1" "" --any-port) && db_server_start "$id" >&2 && echo "$id"' _ "$1"
}
port() { awk -F'\t' -v o="$1" '$2 == o {print $1}' "$HOME/.local/share/devctl/registry/ports.tsv"; }
secret() { sed -n "s/^$2=//p" "$HOME/.local/share/devctl/secrets/servers/$1.env"; }

@test "mailpit: catches an email sent over SMTP" {
  run up mailpit
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'Subject: devctl test\r\n\r\nhello\r\n' >"$BATS_FILE_TMPDIR/mail.txt"
  curl -fsS "smtp://127.0.0.1:$(port mailpit-1-33)" --mail-from a@devctl.test --mail-rcpt b@devctl.test -T "$BATS_FILE_TMPDIR/mail.txt"
  run curl -fsS "http://127.0.0.1:$(port mailpit-1-33/ui)/api/v1/messages"
  echo "$output" | jq -e '.total == 1 and .messages[0].Subject == "devctl test"'
}

@test "meilisearch: master key required" {
  run up meilisearch
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local p key i
  p=$(port meilisearch-1-56); key=$(secret meilisearch-1-56 MEILI_MASTER_KEY)
  for i in $(seq 30); do curl -fs "http://127.0.0.1:$p/health" >/dev/null && break; sleep 1; done
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/indexes")" = 401 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $key" "http://127.0.0.1:$p/indexes")" = 200 ]
}

@test "rustfs: S3 bucket created with signed requests; data written as you" {
  run up rustfs
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local p ak sk i
  p=$(port rustfs-1-0-4); ak=$(secret rustfs-1-0-4 RUSTFS_ACCESS_KEY); sk=$(secret rustfs-1-0-4 RUSTFS_SECRET_KEY)
  for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$p/" && break; sleep 1; done
  run curl -s -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:us-east-1:s3" --user "$ak:$sk" -X PUT "http://127.0.0.1:$p/itest-bucket"
  [ "$output" = 200 ] || { docker logs --tail 30 devctl-itest-rustfs-1-0-4; return 1; }
  run curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user "$ak:$sk" "http://127.0.0.1:$p/"
  [[ $output == *itest-bucket* ]]
  [ "$(curl -s -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:us-east-1:s3" --user "wrong:wrongwrongwrong" "http://127.0.0.1:$p/")" = 403 ]
  [ "$(find "$HOME/.local/share/devctl/data/rustfs-1-0-4" -mindepth 1 -maxdepth 1 -printf '%u\n' | sort -u)" = "$(id -un)" ]
}

@test "rabbitmq: management API with the generated password" {
  run up rabbitmq
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run curl -fsS -u "devctl:$(secret rabbitmq-4-4 RABBITMQ_DEFAULT_PASS)" "http://127.0.0.1:$(port rabbitmq-4-4/ui)/api/overview"
  echo "$output" | jq -e '.rabbitmq_version | startswith("4.4")'
  [ "$(curl -s -o /dev/null -w '%{http_code}' -u devctl:wrong "http://127.0.0.1:$(port rabbitmq-4-4/ui)/api/overview")" = 401 ]
}

@test "elasticsearch: single node healthy, data written as you" {
  run up elasticsearch
  [ "$status" -eq 0 ] || { echo "$output"; docker logs --tail 30 devctl-itest-elasticsearch-9-5-5; return 1; }
  run curl -fsS "http://127.0.0.1:$(port elasticsearch-9-5-5)/_cluster/health"
  echo "$output" | jq -e '.status == "green" or .status == "yellow"'
  [ -n "$(find "$HOME/.local/share/devctl/data/elasticsearch-9-5-5" -mindepth 1 -maxdepth 1 -user "$(id -u)" -print -quit)" ]
}

@test "kafka: topic created and listed (KRaft, no ZooKeeper)" {
  run up kafka
  [ "$status" -eq 0 ] || { echo "$output"; docker logs --tail 30 devctl-itest-kafka-4-4-0; return 1; }
  local i
  for i in $(seq 40); do docker exec devctl-itest-kafka-4-4-0 /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list >/dev/null 2>&1 && break; sleep 1; done
  docker exec devctl-itest-kafka-4-4-0 /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic itest >/dev/null
  run docker exec devctl-itest-kafka-4-4-0 /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
  [[ $output == *itest* ]]
}
