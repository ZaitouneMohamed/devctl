#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  router__load_command init
  router__load_command doctor
}

@test "dirs: missing folders are listed, then created private" {
  run init_dirs_check
  [[ $output == create* ]]
  ( umask 077; init_dirs_apply )
  [ "$(init_dirs_check)" = ok ]
  [ "$(stat -c %a "$DEVCTL_DATA_DIR/secrets")" = 700 ]
}

@test "dirs: a folder with loose permissions is made private" {
  ( umask 077; init_dirs_apply )
  chmod 755 "$DEVCTL_CONFIG_DIR"
  [[ $(init_dirs_check) == *"make private: ~/.config/devctl"* ]]
  init_dirs_apply
  [ "$(stat -c %a "$DEVCTL_CONFIG_DIR")" = 700 ]
}

@test "dirs: dry-run creates nothing" {
  DEVCTL_DRY_RUN=1
  run init_dirs_apply
  [[ $output == *"[dry-run] Create: mkdir -p -- $HOME/.config/devctl"* ]]
  [ ! -e "$HOME/.config/devctl" ]
}

@test "data: on a non-Btrfs filesystem a plain folder is enough" {
  init__is_btrfs() { return 1; }
  [[ $(init_data_check) == *"not Btrfs"* ]]
  ( umask 077; init_data_apply )
  [ -d "$DEVCTL_DATA_DIR/data" ]
  [ "$(init_data_check)" = ok ]
}

@test "data: on Btrfs, plan subvolume + No-CoW; dry-run shows exact commands" {
  init__is_btrfs() { return 0; }
  [[ $(init_data_check) == *"as a Btrfs subvolume with copy-on-write disabled"* ]]
  DEVCTL_DRY_RUN=1
  run init_data_apply
  [[ $output == *"btrfs -q subvolume create -- $DEVCTL_DATA_DIR/data"* ]]
  [[ $output == *"chattr +C -- $DEVCTL_DATA_DIR/data"* ]]
}

@test "data: an existing empty plain folder is replaced; a non-empty one needs a manual decision" {
  init__is_btrfs() { return 0; }
  init__is_subvolume() { return 1; }
  mkdir -p "$DEVCTL_DATA_DIR/data"
  [[ $(init_data_check) == "replace the empty folder"* ]]
  touch "$DEVCTL_DATA_DIR/data/ibdata1"
  [[ $(init_data_check) == manual:* ]]
  run init_data_apply
  [ "$status" -eq 7 ]
  [ -e "$DEVCTL_DATA_DIR/data/ibdata1" ]   # never deleted
}

@test "data: subvolume with No-CoW is ok" {
  init__is_btrfs() { return 0; }
  init__is_subvolume() { return 0; }
  init__has_nocow() { return 0; }
  mkdir -p "$DEVCTL_DATA_DIR/data"
  [ "$(init_data_check)" = ok ]
}

@test "is_btrfs looks at the nearest existing folder" {
  stat() { [[ $* == "-f -c %T -- $HOME" ]] && echo btrfs || command stat "$@"; }
  init__is_btrfs "$HOME/.local/share/devctl/data"
}

@test "system step reuses doctor's checks" {
  probe_static_hostname() { echo other; }
  probe_unit_enabled() { echo disabled; }
  probe_file_exists() { return 0; }
  probe_file_contains() { return 0; }
  probe_llmnr_global() { echo no; }
  probe_command() { return 0; }
  doctor_check_web() { d_result ok fine; }
  doctor_check_https_trust() { d_result ok fine; }
  doctor_check_watch() { d_result ok fine; }
  [ "$(init_system_check)" = "fix: Hostname (each asked separately)" ]
}

@test "devctl --dry-run init lists steps and changes nothing" {
  run devctl --dry-run init
  [ "$status" -eq 0 ]
  [[ $output == *"devctl folders: create"* ]]
  [ ! -e "$HOME/.config/devctl" ] && [ ! -e "$HOME/.local/share/devctl" ]
}
