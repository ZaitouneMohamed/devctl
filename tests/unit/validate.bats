#!/usr/bin/env bats
load '../helpers/common'

setup() { setup_home; load_core; }

@test "domain labels: valid" {
  for v in ab shop my-shop a1 school-ai-2026 "$(printf 'a%.0s' {1..42})"; do
    is_domain_label "$v" || { echo "rejected: $v"; return 1; }
  done
}

@test "domain labels: invalid" {
  for v in "" a 1shop -shop shop- Shop my_shop my--shop shop.test "sh op" "$(printf 'a%.0s' {1..43})" $'shop\nx'; do
    if is_domain_label "$v"; then echo "accepted: $v"; return 1; fi
  done
}

@test "ports and numbers" {
  is_port 1 && is_port 3306 && is_port 65535
  ! is_port 0 && ! is_port 65536 && ! is_port 080 && ! is_port -1 && ! is_port abc && ! is_port ""
  is_uint 0 && is_uint 42 && ! is_uint 007 && ! is_uint 1.5
  is_percent 0 && is_percent 100 && ! is_percent 101
}

@test "identifiers, versions, booleans" {
  is_identifier laravel-inertia-react && is_identifier mysql && ! is_identifier Mysql && ! is_identifier my_sql && ! is_identifier -x && ! is_identifier x-
  is_version 8 && is_version 8.4 && is_version 8.4.1 && ! is_version 8.4.1.2 && ! is_version v8
  is_bool yes && is_bool OFF && ! is_bool maybe
  bool_true On && ! bool_true no
}

@test "path_is_within resolves .. and rejects escapes" {
  path_is_within /home/u/projects /home/u/projects/a/b
  path_is_within /home/u/projects /home/u/projects
  ! path_is_within /home/u/projects /home/u/projects/../secrets
  ! path_is_within /home/u/projects /home/u/projects-evil
}

@test "require_valid dies with EX_VALIDATION and a hint" {
  run require_valid domain_label Bad_Name "project name"
  [ "$status" -eq 3 ]
  [[ $output == *"invalid project name 'Bad_Name'"* ]]
  [[ $output == *"lowercase"* ]]
}
