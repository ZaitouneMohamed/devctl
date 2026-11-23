#!/usr/bin/env bats
load '../helpers/common'

# Fake docker + systemctl. State lives in files under $BATS_TEST_TMPDIR:
#   docker-state   "active" or "inactive" (what systemctl reports for docker.service)
#   docker.log     every docker call (argv)
fake_engine() {
  local dir="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$dir"
  echo "${1:-active}" >"$BATS_TEST_TMPDIR/docker-state"
  cat >"$dir/systemctl" <<STUB
#!/bin/sh
state=\$(cat "$BATS_TEST_TMPDIR/docker-state")
case "\$1 \$2" in
  "is-active --quiet") [ "\$state" = active ] ;;
  "is-enabled docker.service"|"is-enabled docker.socket") echo disabled ;;
  *) exit 0 ;;
esac
STUB
  cat >"$dir/docker" <<STUB
#!/bin/sh
echo "docker \$*" >>"$BATS_TEST_TMPDIR/docker.log"
case "\$1" in
  version) echo 29.9.2 ;;
  info) [ "\$(cat "$BATS_TEST_TMPDIR/docker-state")" = active ] ;;
  ps) [ "\$2" = "-q" ] && printf 'a\nb\n' || printf 'devctl-mysql-8-4\trunning\tmysql:8.4\n' ;;
  inspect) [ "\$4" = "--" ] && [ "\$5" = known ] && echo running || exit 1 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$dir/systemctl" "$dir/docker"
  export PATH="$dir:$PATH"
}

setup() {
  setup_home
  load_core
  adapter_load engine
}

@test "adapter_load: configured adapter, unknown name rejected" {
  [ "$(ce_name)" = docker ]
  write_user_config 'engine.adapter = podman'
  run config_load
  [ "$status" -eq 3 ]          # not in the enum: rejected at config time
}

@test "running state comes from systemctl, never from the docker CLI" {
  fake_engine inactive
  ! ce_daemon_running
  fake_engine active
  ce_daemon_running
  [ ! -e "$BATS_TEST_TMPDIR/docker.log" ]
}

@test "ensure_running starts Docker through the helper and waits" {
  fake_engine inactive
  priv_run() { echo "priv_run $*" >>"$BATS_TEST_TMPDIR/priv.log"; echo active >"$BATS_TEST_TMPDIR/docker-state"; }
  run ce_ensure_running
  [ "$status" -eq 0 ]
  [[ $output == *"Docker is running"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/priv.log")" = "priv_run --desc Start Docker docker-start" ]
}

@test "ensure_running gives up with a hint when Docker never gets ready" {
  fake_engine inactive
  priv_run() { :; }
  CE_START_TIMEOUT=1
  run ce_ensure_running
  [ "$status" -eq 9 ]
  [[ $output == *"journalctl -u docker"* ]]
}

@test "ensure_running does nothing when already running" {
  fake_engine active
  priv_run() { echo called >"$BATS_TEST_TMPDIR/priv.log"; }
  ce_ensure_running
  [ ! -e "$BATS_TEST_TMPDIR/priv.log" ]
}

@test "compose up/down: exact commands; down never removes volumes" {
  fake_engine active
  ce_up devctl-mysql-8-4 /x/compose.yaml
  ce_down devctl-mysql-8-4 /x/compose.yaml
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/docker.log")" = "docker compose --project-name devctl-mysql-8-4 --file /x/compose.yaml up --detach --wait" ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/docker.log")" = "docker compose --project-name devctl-mysql-8-4 --file /x/compose.yaml down" ]
  ! grep -q -- '--volumes\|-v ' "$BATS_TEST_TMPDIR/docker.log"
}

@test "status of a missing container is 'missing'" {
  fake_engine active
  [ "$(ce_status known)" = running ]
  [ "$(ce_status nope)" = missing ]
}

@test "exec passes arguments as separate words" {
  fake_engine active
  ce_exec ctr -- mysql -e 'SELECT 1; DROP x'
  [ "$(cat "$BATS_TEST_TMPDIR/docker.log")" = "docker exec --interactive -- ctr mysql -e SELECT 1; DROP x" ]
}

@test "devctl engine status (json) and stop asks first" {
  fake_engine active
  run devctl --json engine status
  echo "$output" | jq -e '.running == true and .running_containers == 2 and .devctl_containers == 1 and .starts_at_boot == false'
  run devctl engine stop </dev/null
  [ "$status" -eq 7 ]          # 2 containers running → needs a confirmation
  fake_engine inactive
  run devctl engine stop
  [[ $output == *"not running"* ]]
}

@test "dry-run shows privileged plans even when the helper needs updating" {
  fake_engine inactive
  DEVCTL_ROOT_HELPER="$BATS_TEST_TMPDIR/missing-helper"
  DEVCTL_DRY_RUN=1
  run ce_ensure_running
  [ "$status" -eq 0 ]
  [[ $output == *"a real run needs 'devctl root install' first"* ]]
  [[ $output == *"[dry-run] Start Docker: sudo -- $BATS_TEST_TMPDIR/missing-helper docker-start"* ]]
}

helper_fn() { bash -c 'source "$1"; logger() { :; }; shift; "$@"' _ "$REPO_ROOT/libexec/devctl-root" "$@"; }

@test "helper: docker-start/stop take no arguments" {
  run helper_fn verb_docker_start now
  [ "$status" -eq 64 ]
  run helper_fn verb_docker_stop now
  [ "$status" -eq 64 ]
}
