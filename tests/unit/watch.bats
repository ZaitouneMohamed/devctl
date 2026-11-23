#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  router__load_command watch
  notify() { echo "NOTIFY $*" >>"$BATS_TEST_TMPDIR/notify.log"; }
}

@test "disk: ok above the limit, alert once (then at most every 6 h)" {
  df() { printf 'Use%%\n 50%%\n'; }
  [[ $(watch_check_disk) == "ok: 50% free" ]]
  df() { printf 'Use%%\n 90%%\n'; }
  [[ $(watch_check_disk) == "alert: only 10% free" ]]
  watch_check_disk >/dev/null
  [ "$(grep -c 'Disk almost full' "$BATS_TEST_TMPDIR/notify.log")" -eq 1 ]
  [ "$(jq -r 'select(.type == "alert") | .code' "$DEVCTL_HISTORY_FILE")" = disk-low ]
  WATCH_FORCE=1 watch_check_disk >/dev/null
  [ "$(grep -c 'Disk almost full' "$BATS_TEST_TMPDIR/notify.log")" -eq 2 ]
}

@test "disk: recovering resets the reminder" {
  df() { printf 'Use%%\n 90%%\n'; }
  watch_check_disk >/dev/null
  df() { printf 'Use%%\n 40%%\n'; }
  watch_check_disk >/dev/null
  df() { printf 'Use%%\n 90%%\n'; }
  watch_check_disk >/dev/null
  [ "$(grep -c 'Disk almost full' "$BATS_TEST_TMPDIR/notify.log")" -eq 2 ]
}

@test "crashes: skipped without Docker; each crash notified once" {
  ce_daemon_running() { return 1; }
  [[ $(watch_check_crashes) == "skipped: Docker not running" ]]
  ce_daemon_running() { return 0; }
  ce_crashed() { printf 'devctl-mysql-8-4\t137\t3\t2026-11-11T10:00:00Z\n'; }
  [[ $(watch_check_crashes) == "alert: 1 crashed container(s)" ]]
  watch_check_crashes >/dev/null
  [ "$(grep -c 'Container stopped: devctl-mysql-8-4' "$BATS_TEST_TMPDIR/notify.log")" -eq 1 ]
  ce_crashed() { printf 'devctl-mysql-8-4\t137\t3\t2026-11-11T12:00:00Z\n'; }   # crashed again later
  watch_check_crashes >/dev/null
  [ "$(grep -c 'Container stopped' "$BATS_TEST_TMPDIR/notify.log")" -eq 2 ]
}

@test "images: daily, only downloaded images, each new digest notified once, never pulls" {
  ce_daemon_running() { return 0; }
  ensure_private_dir "$DEVCTL_DATA_DIR/registry"
  printf 'mysql-8-4\tmysql\t8.4\tmysql:8.4\t3306\t2026-11-05\nredis-8-8\tredis\t8.8\tredis:8.8\t6379\t2026-11-05\n' >"$DB_SERVERS_FILE"
  ce_image_local_digest() { [[ $1 == mysql:8.4 ]] && echo sha256:old; }
  ce_image_remote_digest() { echo sha256:new; }
  ce_pull() { echo PULLED >>"$BATS_TEST_TMPDIR/notify.log"; }
  [[ $(watch_check_images) == "alert: newer image(s): mysql:8.4" ]]
  [[ $(watch_check_images) == "skipped: checked in the last 24 h" ]]
  WATCH_FORCE=1 watch_check_images >/dev/null
  [ "$(grep -c 'Newer image: mysql:8.4' "$BATS_TEST_TMPDIR/notify.log")" -eq 1 ]
  ! grep -q PULLED "$BATS_TEST_TMPDIR/notify.log"
  ! grep -q redis "$BATS_TEST_TMPDIR/notify.log"
}

@test "tick runs every check and never fails" {
  watch_check_images() { return 3; }
  run cmd_watch_tick
  [ "$status" -eq 0 ]
  [[ $output == *"images   skipped: check failed"* ]]
}

@test "enable: unit files point at this repo; dry-run writes nothing" {
  run devctl --dry-run --yes watch enable
  [ ! -e "$HOME/.config/systemd/user/devctl-watch.timer" ]
  grep -q '^ExecStart=@DEVCTL_BIN@ --quiet watch tick$' "$REPO_ROOT/share/systemd/user/devctl-watch.service.in"
  grep -q '^Environment=DEVCTL_SOURCE=timer$' "$REPO_ROOT/share/systemd/user/devctl-watch.service.in"
  grep -q '^OnUnitActiveSec=30min$' "$REPO_ROOT/share/systemd/user/devctl-watch.timer"
}

@test "enable then disable (systemctl stubbed)" {
  stub_commands systemctl
  devctl --yes watch enable
  grep -qx "ExecStart=$REPO_ROOT/bin/devctl --quiet watch tick" "$HOME/.config/systemd/user/devctl-watch.service"
  grep -q 'systemctl --user enable --now devctl-watch.timer' "$BATS_TEST_TMPDIR/stub.log"
  devctl watch disable
  [ ! -e "$HOME/.config/systemd/user/devctl-watch.timer" ]
}
