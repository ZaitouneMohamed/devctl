#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load '../helpers/common'

setup() { setup_home; load_core; }

@test "redacts key=value secrets and URL passwords" {
  run log_redact 'DB_PASSWORD=hunter2 api_key: abc123 token="x y" user=bob mysql://app:s3cret@127.0.0.1/db'
  [[ $output != *hunter2* && $output != *abc123* && $output != *'x y'* && $output != *s3cret* ]]
  [[ $output == *'DB_PASSWORD=****'* && $output == *'user=bob'* && $output == *'mysql://app:****@127.0.0.1'* ]]
}

@test "default stderr level hides info, shows warn; file gets info" {
  run --separate-stderr log_info "hello-info"
  [ -z "$stderr" ]
  run --separate-stderr log_warn "hello-warn"
  [[ $stderr == *"warning: hello-warn"* ]]
  grep -q 'info  hello-info' "$(log_file_path)"
}

@test "secrets never reach the log file" {
  log_warn "connecting with PASSWORD=topsecret"
  ! grep -q topsecret "$(log_file_path)"
}

@test "log dir is 700 and file is 600" {
  ( umask 077; log_warn x )
  [ "$(stat -c %a "$DEVCTL_LOG_DIR")" = 700 ]
  [ "$(stat -c %a "$(log_file_path)")" = 600 ]
}

@test "unwritable log dir degrades to a single warning" {
  mkdir -p "${DEVCTL_LOG_DIR%/*}"
  : >"$DEVCTL_LOG_DIR"   # a file where the dir should be
  run --separate-stderr log_warn one
  [ "$status" -eq 0 ]
  [[ $stderr == *"cannot write log file"* ]]
}

@test "log_prune keeps DAYS days" {
  mkdir -p "$DEVCTL_LOG_DIR"
  touch -d '8 days ago' "$DEVCTL_LOG_DIR/devctl-old.log"
  touch -d '6 days ago' "$DEVCTL_LOG_DIR/devctl-recent.log"
  touch -d '30 days ago' "$DEVCTL_LOG_DIR/other.txt"
  log_prune 7
  [ ! -e "$DEVCTL_LOG_DIR/devctl-old.log" ]
  [ -e "$DEVCTL_LOG_DIR/devctl-recent.log" ]
  [ -e "$DEVCTL_LOG_DIR/other.txt" ]
  run log_prune 0
  [ "$status" -eq 1 ]
}
