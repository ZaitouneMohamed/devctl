#!/usr/bin/env bats
load '../helpers/common'

setup() { setup_home; load_core; }

@test "action record is one valid JSON line with expected fields" {
  history_record_action site.create 0 120 shop --template laravel-inertia-react
  [ "$(wc -l <"$DEVCTL_HISTORY_FILE")" -eq 1 ]
  jq -e '.type == "action" and .action == "site.create" and .result == "ok" and .exit == 0
         and .duration_ms == 120 and .source == "cli" and .args == ["shop","--template","laravel-inertia-react"]' \
    "$DEVCTL_HISTORY_FILE"
}

@test "results: failed, aborted, dry-run" {
  history_record_action a.b 1 0
  history_record_action a.b 6 0
  DEVCTL_DRY_RUN=1 history_record_action a.b 0 0
  [ "$(jq -r .result "$DEVCTL_HISTORY_FILE" | paste -sd,)" = "failed,aborted,dry-run" ]
}

@test "secret arguments are masked in all forms" {
  history_record_action db.create 0 0 --password hunter2 --db-token=abc DB_PASSWORD=xyz --name shop
  ! grep -Eq 'hunter2|abc|xyz' "$DEVCTL_HISTORY_FILE"
  jq -e '.args == ["--password","****","--db-token=****","DB_PASSWORD=****","--name","shop"]' "$DEVCTL_HISTORY_FILE"
}

@test "source comes from DEVCTL_SOURCE and is validated" {
  DEVCTL_SOURCE=dashboard history_record_action x 0 0
  DEVCTL_SOURCE=evil history_record_action x 0 0
  [ "$(jq -r .source "$DEVCTL_HISTORY_FILE" | paste -sd,)" = "dashboard,cli" ]
}

@test "alerts are recorded and validated" {
  history_record_alert warn disk-low "12% free; token=abc"
  jq -e '.type == "alert" and .level == "warn" and .code == "disk-low"' "$DEVCTL_HISTORY_FILE"
  ! grep -q abc "$DEVCTL_HISTORY_FILE"
  run history_record_alert panic x y
  [ "$status" -eq 1 ]
}

@test "special characters survive as JSON" {
  history_record_action x 0 0 $'line1\nline2' 'quote " back\slash' --leading-dashes ''
  jq -e '.args == ["line1\nline2", "quote \" back\\slash", "--leading-dashes", ""]' "$DEVCTL_HISTORY_FILE"
}

@test "history file is 600" {
  ( umask 077; history_record_action x 0 0 )
  [ "$(stat -c %a "$DEVCTL_HISTORY_FILE")" = 600 ]
}

@test "unwritable history only warns" {
  mkdir -p "$DEVCTL_HISTORY_FILE"   # a directory where the file should be
  run history_record_action x 0 0
  [ "$status" -eq 0 ]
  [[ $output == *"could not write history"* ]]
}

@test "json_array: empty list, empty string, leading dashes" {
  [ "$(json_array)" = '[]' ]
  [ "$(json_array '')" = '[""]' ]
  [ "$(json_array --x -- '-' )" = '["--x","--","-"]' ]
}
