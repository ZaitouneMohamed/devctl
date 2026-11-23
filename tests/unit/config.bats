#!/usr/bin/env bats
load '../helpers/common'

setup() { setup_home; load_core; }

@test "defaults load with origin 'default'" {
  [ "$(config_get domain.suffix)" = test ]
  [ "$(config_origin domain.suffix)" = default ]
}

@test "user file overrides defaults; quotes and trailing comments are stripped" {
  write_user_config 'domain.suffix = localtest   # my choice' 'projects.categories = "elden personal"'
  config_load
  [ "$(config_get domain.suffix)" = localtest ]
  [ "$(config_origin domain.suffix)" = user ]
  [ "$(config_get projects.categories)" = "elden personal" ]
}

@test "env overrides user file" {
  write_user_config 'log.retention_days = 10'
  DEVCTL_CFG_LOG_RETENTION_DAYS=14 config_load
  [ "$(config_get log.retention_days)" = 14 ]
  [ "$(config_origin log.retention_days)" = env ]
}

@test "values are literal: no expansion or command substitution" {
  write_user_config 'projects.root = /tmp/$(touch pwned)/${HOME}'
  config_load
  [ "$(config_get projects.root)" = '/tmp/$(touch pwned)/${HOME}' ]
  [ ! -e pwned ] && [ ! -e "$HOME/pwned" ]
}

@test "unknown key in user file is ignored with a warning" {
  write_user_config 'no.such.key = 1'
  run config_load
  [ "$status" -eq 0 ]
  [[ $output == *"unknown setting 'no.such.key' ignored"* ]]
}

@test "invalid line is rejected with file and line number" {
  write_user_config '# ok' 'not a setting'
  run config_load
  [ "$status" -eq 3 ]
  [[ $output == *"devctl.conf:2: invalid line"* ]]
}

@test "typed validation rejects bad values" {
  write_user_config 'guard.disk_min_free_percent = 150'
  run config_load
  [ "$status" -eq 3 ]
  [[ $output == *"guard.disk_min_free_percent"* && $output == *"0 to 100"* ]]
  write_user_config 'ui.color = purple'
  run config_load
  [ "$status" -eq 3 ]
}

@test "group/world-writable user config is refused" {
  write_user_config 'domain.suffix = test'
  chmod 664 "$HOME/.config/devctl/devctl.conf"
  run config_load
  [ "$status" -eq 7 ]
  [[ $output == *"chmod 600"* ]]
}

@test "config_get_path expands only a leading ~" {
  [ "$(config_get_path projects.root)" = "$HOME/Desktop/projects" ]
  write_user_config 'projects.root = /srv/x~y'
  config_load
  [ "$(config_get_path projects.root)" = "/srv/x~y" ]
}

@test "config_set validates and marks origin flag" {
  config_set ui.color never
  [ "$(config_origin ui.color)" = flag ]
  run config_set ui.color purple
  [ "$status" -eq 3 ]
}

@test "unknown key in code is a bug (EX_FAIL)" {
  run config_get no.such.key
  [ "$status" -eq 1 ]
}

@test "CRLF line endings are accepted" {
  mkdir -p "$HOME/.config/devctl"
  printf 'domain.suffix = crlf\r\n' >"$HOME/.config/devctl/devctl.conf"
  chmod 600 "$HOME/.config/devctl/devctl.conf"
  config_load
  [ "$(config_get domain.suffix)" = crlf ]
}
