#!/usr/bin/env bats
# End-to-end tests of bin/devctl: flags, dispatch, exit codes, history, traps.
bats_require_minimum_version 1.5.0
load '../helpers/common'

setup() { setup_home; }

@test "no arguments prints usage" {
  run devctl
  [ "$status" -eq 0 ]
  [[ $output == *"Usage: devctl"* && $output == *"version"* ]]
}

@test "version, json version" {
  run devctl version
  [[ $output == "devctl "* ]]
  run devctl --json version
  echo "$output" | jq -e '.version'
}

@test "unknown command, option, subcommand -> EX_USAGE" {
  run devctl nope
  [ "$status" -eq 2 ]
  run devctl --nope
  [ "$status" -eq 2 ]
  run devctl ../../etc/passwd
  [ "$status" -eq 2 ]
  run devctl version extra
  [ "$status" -eq 2 ]
}

@test "help for a command, two ways" {
  run devctl help config
  [[ $output == *"devctl config get"* ]]
  run devctl config --help
  [[ $output == *"devctl config get"* ]]
}

@test "config get / unknown key" {
  run devctl config get domain.suffix
  [ "$output" = test ]
  run devctl config get nope
  [ "$status" -eq 4 ]
}

@test "--quiet with --verbose conflicts" {
  run devctl -q -v version
  [ "$status" -eq 2 ]
}

@test "works through a symlink (as installed in ~/.local/bin)" {
  mkdir -p "$HOME/.local/bin"
  ln -s "$REPO_ROOT/bin/devctl" "$HOME/.local/bin/devctl"
  run "$HOME/.local/bin/devctl" version
  [ "$status" -eq 0 ]
}

@test "empty HOME is refused" {
  HOME= run "$REPO_ROOT/bin/devctl" version
  [ "$status" -eq 7 ]
}

@test "registered actions are recorded in history, queries are not" {
  local repo
  repo=$(make_sandbox)
  cat >"$repo/lib/cmd/fake.sh" <<'CMD'
# summary: test command
register_action fake.do
cmd_fake_do() { [[ ${1:-} == fail ]] && return 9; ui_ok "did it"; }
cmd_fake_look() { echo looked; }
CMD
  "$repo/bin/devctl" fake look
  "$repo/bin/devctl" fake do --token secret1 one
  run "$repo/bin/devctl" fake do fail
  [ "$status" -eq 9 ]
  DEVCTL_SOURCE=dashboard "$repo/bin/devctl" --dry-run fake do
  local h="$HOME/.local/state/devctl/history.jsonl"
  [ "$(wc -l <"$h")" -eq 3 ]
  [ "$(jq -r '.result' "$h" | paste -sd,)" = "ok,failed,dry-run" ]
  [ "$(jq -r '.source' "$h" | paste -sd,)" = "cli,cli,dashboard" ]
  ! grep -q secret1 "$h"
}

@test "temp files are removed on exit, also after an error" {
  local repo
  repo=$(make_sandbox)
  cat >"$repo/lib/cmd/tmp.sh" <<'CMD'
# summary: test command
cmd_tmp() { local f; make_temp_file f; echo "$f"; [[ ${1:-} == fail ]] && false; return 0; }
CMD
  run "$repo/bin/devctl" tmp
  [ "$status" -eq 0 ]
  [ ! -e "$output" ]
  run --separate-stderr "$repo/bin/devctl" tmp fail
  [ "$status" -eq 1 ]
  [[ $stderr == *"unexpected failure"* ]]
  [ ! -e "$output" ]
}

@test "typed confirmation via --confirm" {
  local repo
  repo=$(make_sandbox)
  cat >"$repo/lib/cmd/del.sh" <<'CMD'
# summary: test command
cmd_del() { confirm_typed "$1" || die "$EX_ABORTED" "aborted"; echo deleted; }
CMD
  run "$repo/bin/devctl" --confirm=shop del shop
  [ "$output" = deleted ]
  run "$repo/bin/devctl" --yes --confirm=nope del shop
  [ "$status" -eq 6 ]
}

@test "config show --json survives values starting with --" {
  write_user_config 'projects.root = /tmp/--weird'
  run devctl --json config show
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.key == "projects.root") | .value == "/tmp/--weird"'
}

@test "typos get suggestions" {
  run devctl confg
  [ "$status" -eq 2 ]
  [[ $output == *"did you mean: config?"* ]]
  run devctl dashboard stp
  [ "$status" -eq 2 ]
  [[ $output == *"did you mean: stop?"* ]]
  run devctl config gt
  [[ $output == *"did you mean: get?"* ]]
}

@test "hidden commands are not listed in usage" {
  run devctl help
  [[ $output != *"complete "* ]]
}

@test "router_mark_action records conditional actions" {
  local repo
  repo=$(make_sandbox)
  cat >"$repo/lib/cmd/maybe.sh" <<'CMD'
# summary: test command
cmd_maybe() { [[ ${1:-} == change ]] && router_mark_action maybe.changed; return 0; }
CMD
  "$repo/bin/devctl" maybe
  "$repo/bin/devctl" maybe change
  [ "$(jq -r .action "$HOME/.local/state/devctl/history.jsonl")" = maybe.changed ]
}
