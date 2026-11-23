#!/usr/bin/env bats
load '../helpers/common'

setup() { setup_home; load_core; }

@test "acquire and release" {
  lock_acquire sites 1
  [ -n "${__LOCK_FDS[sites]}" ]
  lock_release sites
  [ -z "${__LOCK_FDS[sites]:-}" ]
  lock_release sites   # releasing twice is harmless
}

@test "a second process times out with EX_CONFLICT" {
  lock_acquire sites 1
  run bash -c "export DEVCTL_ROOT='$REPO_ROOT'; source '$REPO_ROOT/lib/core/bootstrap.sh'; config_load; lock_acquire sites 1"
  [ "$status" -eq 5 ]
  [[ $output == *"busy with 'sites'"* ]]
}

@test "lock is free again after the holder exits" {
  bash -c "export DEVCTL_ROOT='$REPO_ROOT'; source '$REPO_ROOT/lib/core/bootstrap.sh'; config_load; lock_acquire sites 1"
  lock_acquire sites 1
}

@test "with_lock returns the command status and releases" {
  run with_lock sites -- sh -c 'exit 4'
  [ "$status" -eq 4 ]
  with_lock sites -- true
  [ -z "${__LOCK_FDS[sites]:-}" ]
}

@test "lock names are validated" {
  run lock_acquire ../../etc/passwd 1
  [ "$status" -eq 1 ]
}
