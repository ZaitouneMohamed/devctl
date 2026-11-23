# shellcheck shell=bash
# summary: Bring this machine to the devctl baseline (safe to run again; asks first)

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action init

# Steps in order. Each init_<id>_check prints "ok" or a one-line description of what is
# missing; init_<id>_apply does it. Later modules add steps (runtimes, Caddy, CA trust,
# background timer) to this list.
readonly INIT_STEPS=(dirs data install helper system runtimes)

declare -gA INIT_TITLES=(
  [dirs]="devctl folders" [data]="Database data folder" [install]="Command, completion, launchers"
  [helper]="Privileged helper" [system]="System settings" [runtimes]="Language runtimes"
)

# Folders devctl owns; all private (0700).
init__dirs() {
  printf '%s\n' "$DEVCTL_CONFIG_DIR" "$DEVCTL_DATA_DIR" "$DEVCTL_DATA_DIR/secrets" \
    "$DEVCTL_DATA_DIR/registry" "$DEVCTL_STATE_DIR" "$DEVCTL_LOG_DIR" "$DEVCTL_RUN_DIR" "$DEVCTL_CACHE_DIR"
}

init_dirs_check() {
  local dir missing=() loose=()
  while IFS= read -r dir; do
    if [[ ! -d $dir ]]; then
      missing+=("${dir/#$HOME/\~}")
    elif [[ $(stat -c %a -- "$dir") != 700 ]]; then
      loose+=("${dir/#$HOME/\~}")
    fi
  done < <(init__dirs)
  if ((${#missing[@]} + ${#loose[@]} == 0)); then
    printf 'ok\n'
  else
    printf 'create %s; make private: %s\n' "${missing[*]:-nothing}" "${loose[*]:-nothing}"
  fi
}

# devctl runs with umask 077, so every folder mkdir creates (parents too) is 0700.
init_dirs_apply() {
  local dir
  while IFS= read -r dir; do
    if [[ ! -d $dir ]]; then
      run_change --desc "Create" -- mkdir -p -- "$dir" || return
    elif [[ $(stat -c %a -- "$dir") != 700 ]]; then
      run_change --desc "Make private" -- chmod 700 -- "$dir" || return
    fi
  done < <(init__dirs)
}

# Database data: a Btrfs subvolume with copy-on-write disabled (ADR-0008). +C only takes
# effect for files created afterwards, so it must be set while the folder is empty.
init__data_dir() { printf '%s/data\n' "$DEVCTL_DATA_DIR"; }

# init__is_btrfs PATH — the filesystem PATH is (or will be) on, judged from the nearest
# existing folder, so the answer is right before devctl's folders exist (e.g. --dry-run).
init__is_btrfs() {
  local path=$1
  while [[ ! -e $path && $path == /* && $path != / ]]; do path=${path%/*}; done
  [[ $(stat -f -c %T -- "${path:-/}" 2>/dev/null) == btrfs ]]
}
init__is_subvolume() { [[ $(stat -c %i -- "$1" 2>/dev/null) == 256 ]]; }
init__has_nocow() { lsattr -d -- "$1" 2>/dev/null | awk '{print $1}' | grep -q C; }

init_data_check() {
  local dir parent
  dir=$(init__data_dir)
  parent=${dir%/*}
  if ! init__is_btrfs "$parent"; then
    [[ -d $dir ]] && { printf 'ok\n'; return; }
    printf 'create %s (not Btrfs: no subvolume needed)\n' "${dir/#$HOME/\~}"
    return
  fi
  if [[ ! -e $dir ]]; then
    printf 'create %s as a Btrfs subvolume with copy-on-write disabled\n' "${dir/#$HOME/\~}"
  elif init__is_subvolume "$dir" && init__has_nocow "$dir"; then
    printf 'ok\n'
  elif [[ -z $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
    printf 'replace the empty folder %s with a No-CoW subvolume\n' "${dir/#$HOME/\~}"
  else
    printf 'manual: %s is not a No-CoW subvolume and is not empty (see docs/modules/05-init.md)\n' "${dir/#$HOME/\~}"
  fi
}

init_data_apply() {
  local dir
  dir=$(init__data_dir)
  [[ $(init_data_check) == manual:* ]] && die "$EX_PRECONDITION" "$(init_data_check)"
  if ! init__is_btrfs "${dir%/*}"; then
    run_change --desc "Create" -- mkdir -p -- "$dir"
    return
  fi
  if [[ -d $dir ]] && ! init__is_subvolume "$dir"; then
    run_change --desc "Remove the empty folder" -- rmdir -- "$dir" || return
  fi
  if [[ ! -e $dir ]] || ((DEVCTL_DRY_RUN)); then
    run_change --desc "Create subvolume" -- btrfs -q subvolume create -- "$dir" || return
  fi
  run_change --desc "Disable copy-on-write (while empty)" -- chattr +C -- "$dir" || return
  run_change --desc "Make private" -- chmod 700 -- "$dir"
}

init_install_check() {
  if [[ $(doctor_status_of install) == ok ]]; then
    printf 'ok\n'
  else
    printf 'install the devctl command, Tab completion and launchers\n'
  fi
}
init_install_apply() { cmd_self_install; }

init_helper_check() {
  if [[ $(priv_helper_state) == ok ]]; then
    printf 'ok\n'
  else
    printf 'install/update the privileged helper (sudo password)\n'
  fi
}
init_helper_apply() { doctor_fix_helper; }

# System settings = doctor's fixable system checks (one source of truth for both).
readonly INIT_SYSTEM_CHECKS=(hostname docker-boot docker-pools llmnr certutil web https-trust watch)

init_system_check() {
  local id todo=()
  for id in "${INIT_SYSTEM_CHECKS[@]}"; do
    [[ $(doctor_status_of "$id") == ok ]] || todo+=("$(doctor_title "$id")")
  done
  if ((${#todo[@]} == 0)); then
    printf 'ok\n'
  else
    local IFS=,
    printf 'fix: %s (each asked separately)\n' "${todo[*]}"
  fi
}

init_system_apply() {
  local id todo=()
  for id in "${INIT_SYSTEM_CHECKS[@]}"; do
    doctor_fixable "$id" && todo+=("$id")
  done
  ((${#todo[@]})) || return 0
  doctor__offer_fixes "${todo[@]}" || true
}

init_runtimes_check() {
  local rt bad=()
  for rt in php node java python shell; do
    [[ $("rt_${rt}_state") == ok ]] || bad+=("$rt")
  done
  ((${#bad[@]} == 0)) && printf 'ok\n' || printf 'set up: %s\n' "${bad[*]}"
}
init_runtimes_apply() { cmd_runtime_setup all; }

cmd_init() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl init"
  router__load_command doctor
  router__load_command self
  router__load_command root
  router__load_command runtime

  local id state todo=()
  ui_header "devctl init — what this machine still needs"
  for id in "${INIT_STEPS[@]}"; do
    state=$("init_${id}_check")
    if [[ $state == ok ]]; then
      ui_skip "${INIT_TITLES[$id]}: done"
    else
      printf '%s %s: %s\n' "$(ui_paint 1 cyan '→')" "${INIT_TITLES[$id]}" "$state"
      todo+=("$id")
    fi
  done

  if ((${#todo[@]} == 0)); then
    ui_ok "Nothing to do: this machine matches the devctl baseline"
    return 0
  fi
  printf '\n'
  confirm_or_abort "Apply these ${#todo[@]} step(s)? (system changes ask again, one by one)"

  for id in "${todo[@]}"; do
    ui_header "${INIT_TITLES[$id]}"
    "init_${id}_apply" || die "$EX_FAIL" "step '${INIT_TITLES[$id]}' failed; fix the problem above and run devctl init again"
    if ((!DEVCTL_DRY_RUN)); then
      state=$("init_${id}_check")
      if [[ $state == ok ]]; then
        ui_ok "${INIT_TITLES[$id]}: done"
      else
        ui_note "${INIT_TITLES[$id]}: still to do — $state"
      fi
    fi
  done
  ((DEVCTL_DRY_RUN)) || ui_note "Check everything with: devctl doctor"
}

help_init() {
  cat <<'HELP'
Usage: devctl init              show what is missing, ask, then do it
       devctl --dry-run init    show the exact commands, change nothing

Brings this laptop (or a fresh Fedora install) to the devctl baseline. Safe to run again:
finished steps are skipped. Steps today:
  devctl folders            ~/.config/devctl, ~/.local/share/devctl/{secrets,registry}, … (0700)
  Database data folder      ~/.local/share/devctl/data: Btrfs subvolume, copy-on-write off
  Command, completion, …    same as devctl self install
  Privileged helper         same as devctl root install (sudo password)
  System settings           hostname, Docker not at boot, Docker address pools, LLMNR off,
                            certutil — each asked separately (same fixes as devctl doctor)
Later modules add: language runtimes, Caddy and HTTPS trust, background checks.
HELP
}
