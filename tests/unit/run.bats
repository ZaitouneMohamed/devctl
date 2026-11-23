#!/usr/bin/env bats
load '../helpers/common'

setup() { setup_home; load_core; }

@test "run_change executes and returns the status" {
  run_change -- touch "$BATS_TEST_TMPDIR/made"
  [ -e "$BATS_TEST_TMPDIR/made" ]
  run run_change -- false
  [ "$status" -eq 1 ]
  run run_change -- sh -c 'exit 9'
  [ "$status" -eq 9 ]
}

@test "dry-run prints a quoted command and changes nothing" {
  DEVCTL_DRY_RUN=1
  run run_change --desc "Create file" -- touch "$BATS_TEST_TMPDIR/a b"
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] Create file: touch "*'a\ b'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/a b" ]
}

@test "arguments are never re-parsed by a shell" {
  cd "$BATS_TEST_TMPDIR"
  run_change -- touch 'x; touch pwned' '$(touch pwned2)'
  [ -e 'x; touch pwned' ] && [ -e '$(touch pwned2)' ]
  [ ! -e pwned ] && [ ! -e pwned2 ]
}

@test "logged command is redacted" {
  run_change -- true --password=hunter2
  ! grep -q hunter2 "$(log_file_path)"
}

@test "missing command is a bug" {
  run run_change --desc x --
  [ "$status" -eq 1 ]
}
