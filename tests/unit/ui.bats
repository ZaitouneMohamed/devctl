#!/usr/bin/env bats
load '../helpers/common'

setup() { setup_home; load_core; }

@test "confirm: --yes answers yes" {
  DEVCTL_ASSUME_YES=1
  confirm "Proceed?"
}

@test "confirm: dry-run answers yes and shows the question" {
  DEVCTL_DRY_RUN=1
  run confirm "Delete things?"
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] would ask: Delete things?"* ]]
}

@test "confirm: refuses without a terminal" {
  run confirm "Proceed?" </dev/null
  [ "$status" -eq 7 ]
  [[ $output == *"not a terminal"* ]]
}

@test "confirm_or_abort exits EX_ABORTED when declined" {
  confirm() { return 1; }
  run confirm_or_abort "Proceed?"
  [ "$status" -eq 6 ]
}

@test "confirm_typed: --yes is NOT enough" {
  DEVCTL_ASSUME_YES=1
  run confirm_typed shop </dev/null
  [ "$status" -eq 7 ]
}

@test "confirm_typed: --confirm text must match exactly" {
  DEVCTL_CONFIRM_TEXT=shop
  confirm_typed shop
  DEVCTL_CONFIRM_TEXT=Shop
  run confirm_typed shop
  [ "$status" -eq 1 ]
}

@test "colors: never/always/auto+NO_COLOR" {
  ui_color_init always
  [[ "$(ui_paint 1 red x)" == $'\e[31mx\e[0m' ]]
  ui_color_init never
  [ "$(ui_paint 1 red x)" = x ]
  NO_COLOR=1 ui_color_init auto
  [ "$(ui_paint 1 red x)" = x ]
  run ui_color_init sometimes
  [ "$status" -eq 1 ]
}

@test "quiet and json hide status lines but not plans" {
  DEVCTL_QUIET=1
  [ -z "$(ui_ok done)" ]
  [ -n "$(ui_plan step)" ]
  DEVCTL_QUIET=0 DEVCTL_JSON=1
  [ -z "$(ui_step working)" ]
}
