# shellcheck shell=bash
# summary: Install, check or remove devctl for your user (no sudo)

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action self.install self.uninstall

# Every launcher devctl writes carries this line, so devctl only ever updates or removes
# its own files.
readonly SELF_MARKER="X-Devctl-Managed=true"
readonly SELF_DESKTOP_TEMPLATE="share/desktop/devctl-dashboard.desktop.in"

# ---- what gets installed ----------------------------------------------------------------

# self__data_dir — $XDG_DATA_HOME or ~/.local/share
self__data_dir() { xdg_dir XDG_DATA_HOME "$HOME/.local/share"; }

# self__desktop_dir — the Desktop folder from ~/.config/user-dirs.dirs, read without eval.
self__desktop_dir() {
  local file line value
  file="$(xdg_dir XDG_CONFIG_HOME "$HOME/.config")/user-dirs.dirs"
  if [[ -r $file ]]; then
    while IFS= read -r line; do
      if [[ $line =~ ^XDG_DESKTOP_DIR=\"(.*)\"$ ]]; then
        value=${BASH_REMATCH[1]}
        value=${value/#\$HOME/$HOME}
        if [[ $value == /* ]]; then
          printf '%s\n' "$value"
          return 0
        fi
      fi
    done <"$file"
  fi
  printf '%s/Desktop\n' "$HOME"
}

# self__items — one item per line: KIND<TAB>NAME<TAB>TARGET<TAB>SOURCE
#   link     TARGET is a symlink to SOURCE in the repo (updates come with the repo)
#   desktop  TARGET is a launcher generated from the template (needs the repo's path)
self__items() {
  local data
  data=$(self__data_dir)
  printf 'link\tcommand\t%s\t%s\n' "$HOME/.local/bin/devctl" "$DEVCTL_ROOT/bin/devctl"
  printf 'link\tcompletion\t%s\t%s\n' "$data/bash-completion/completions/devctl" "$DEVCTL_ROOT/share/completions/devctl.bash"
  printf 'link\ticon\t%s\t%s\n' "$data/icons/hicolor/scalable/apps/devctl.svg" "$DEVCTL_ROOT/share/icons/devctl.svg"
  printf 'desktop\tapp-launcher\t%s\t-\n' "$data/applications/devctl-dashboard.desktop"
  if config_get_bool self.desktop_icon; then
    printf 'desktop\tdesktop-icon\t%s\t-\n' "$(self__desktop_dir)/devctl-dashboard.desktop"
  fi
}

# self__render_desktop FILE — write the launcher for this repo location into FILE.
self__render_desktop() {
  local bin="$DEVCTL_ROOT/bin/devctl" content
  # Desktop-entry Exec lines have their own quoting rules; keep to paths that need none.
  [[ $bin =~ ^[A-Za-z0-9/._+-]+$ ]] ||
    die "$EX_PRECONDITION" "the repo path '$DEVCTL_ROOT' has characters a desktop launcher cannot use; move the repo or set self.desktop_icon = false"
  content=$(<"$DEVCTL_ROOT/$SELF_DESKTOP_TEMPLATE")
  content=${content//@DEVCTL_BIN@/$bin}
  printf '%s\n' "$content" >"$1"
}

# self__state KIND TARGET SOURCE EXPECTED_FILE — ok | missing | outdated | conflict
#   outdated = devctl's own file, but not the current version → safe to replace.
self__state() {
  local kind=$1 target=$2 source=$3 expected=$4
  if [[ $kind == link ]]; then
    if [[ -L $target ]]; then
      [[ $(readlink -- "$target") == "$source" ]] && { printf 'ok\n'; return; }
      printf 'conflict\n'
    elif [[ -f $target ]] && cmp -s -- "$target" "$source"; then
      printf 'outdated\n' # an identical copy (installed by hand earlier): replace with the link
    elif [[ -e $target ]]; then
      printf 'conflict\n'
    else
      printf 'missing\n'
    fi
    return
  fi
  if [[ ! -e $target && ! -L $target ]]; then
    printf 'missing\n'
  elif [[ -f $target && ! -L $target ]] && self__is_ours "$target"; then
    if cmp -s -- "$target" "$expected"; then printf 'ok\n'; else printf 'outdated\n'; fi
  else
    printf 'conflict\n'
  fi
}

# self__is_ours FILE — a launcher written by devctl (marker line, or the earlier
# hand-installed version whose Exec line runs this repo's devctl).
self__is_ours() {
  grep -qxF -- "$SELF_MARKER" "$1" ||
    grep -qxF -- "Exec=$DEVCTL_ROOT/bin/devctl dashboard" "$1"
}

# ---- commands ---------------------------------------------------------------------------

cmd_self() {
  cmd_self_status "$@"
}

cmd_self_status() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl self status"
  local kind name target source state expected rows=()
  make_temp_file expected
  self__render_desktop "$expected"
  while IFS=$'\t' read -r kind name target source; do
    state=$(self__state "$kind" "$target" "$source" "$expected")
    rows+=("$name" "$state" "$target")
  done < <(self__items)

  if ((DEVCTL_JSON)); then
    jq -n --argjson r "$(json_array "${rows[@]}")" \
      '[range(0; $r | length; 3) as $i | {item: $r[$i], state: $r[$i + 1], path: $r[$i + 2]}]'
    return 0
  fi
  {
    printf 'ITEM\tSTATE\tPATH\n'
    for ((i = 0; i < ${#rows[@]}; i += 3)); do
      printf '%s\t%s\t%s\n' "${rows[i]}" "${rows[i + 1]}" "${rows[i + 2]/#$HOME/\~}"
    done
  } | ui_table
}

cmd_self_install() {
  local force=0 kind name target source state expected
  local -a conflicts=()
  while (($#)); do
    case $1 in
      --force) force=1 ;;
      --no-desktop-icon) config_set self.desktop_icon false ;;
      *) die "$EX_USAGE" "usage: devctl self install [--force] [--no-desktop-icon]" ;;
    esac
    shift
  done

  make_temp_file expected
  self__render_desktop "$expected"
  ui_header "Installing devctl for $USER (no sudo)"

  while IFS=$'\t' read -r kind name target source; do
    state=$(self__state "$kind" "$target" "$source" "$expected")
    case $state in
      ok)
        ui_skip "$name: already installed"
        continue
        ;;
      conflict)
        if ((!force)); then
          ui_fail "$name: $target already exists and was not made by devctl"
          conflicts+=("$target")
          continue
        fi
        confirm_or_abort "Replace $target (it will be kept as $target.devctl-backup)?"
        run_change --desc "Back up $name" -- mv -fT -- "$target" "$target.devctl-backup" ||
          die "$EX_EXTERNAL" "could not back up $target"
        ;;
    esac
    self__apply "$kind" "$name" "$target" "$source" "$expected"
    ((DEVCTL_DRY_RUN)) || ui_ok "$name: $([[ $state == missing ]] && echo installed || echo updated)"
  done < <(self__items)

  self__refresh_caches
  if ((${#conflicts[@]})); then
    die "$EX_CONFLICT" "not replaced (not made by devctl): ${conflicts[*]}. Move them away, or re-run with --force to back them up and replace them."
  fi
  self__hints
}

# self__apply KIND NAME TARGET SOURCE EXPECTED_FILE
self__apply() {
  local kind=$1 name=$2 target=$3 source=$4 expected=$5 mode=644
  if [[ ! -d ${target%/*} ]]; then
    run_change --desc "Create folder for $name" -- mkdir -p -- "${target%/*}" ||
      die "$EX_EXTERNAL" "could not create ${target%/*}"
  fi
  if [[ $kind == link ]]; then
    run_change --desc "Link $name" -- ln -sfT -- "$source" "$target" ||
      die "$EX_EXTERNAL" "could not link $target"
    return 0
  fi
  [[ $name == desktop-icon ]] && mode=755 # desktop-icon extensions only launch executable files
  run_change --desc "Write $name" -- install -m "$mode" -T -- "$expected" "$target" ||
    die "$EX_EXTERNAL" "could not write $target"
  if [[ $name == desktop-icon ]] && command -v gio >/dev/null; then
    # Lets the desktop-icons extension start it without an "untrusted launcher" warning.
    run_change --desc "Mark $name as trusted" -- gio set -- "$target" metadata::trusted true ||
      ui_note "could not mark the desktop icon as trusted; right-click it and choose 'Allow Launching'"
  fi
}

# Caches make new launchers/icons show up immediately; failure only delays that.
self__refresh_caches() {
  local data
  data=$(self__data_dir)
  ((DEVCTL_DRY_RUN)) && return 0
  if command -v update-desktop-database >/dev/null && [[ -d $data/applications ]]; then
    update-desktop-database -q -- "$data/applications" 2>/dev/null || true
  fi
  if command -v gtk-update-icon-cache >/dev/null && [[ -d $data/icons/hicolor ]]; then
    gtk-update-icon-cache -q -t -- "$data/icons/hicolor" 2>/dev/null || true
  fi
}

self__hints() {
  ((DEVCTL_DRY_RUN)) && return 0
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    ui_note "$HOME/.local/bin is not in your PATH; add this line to $HOME/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
  ui_note "open a new terminal to use 'devctl' and Tab completion"
}

cmd_self_uninstall() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl self uninstall"
  local kind name target source state expected
  local -a ours=() names=()
  make_temp_file expected
  self__render_desktop "$expected"
  # Ignore self.desktop_icon here: remove the desktop icon if devctl made it.
  config_set self.desktop_icon true
  while IFS=$'\t' read -r kind name target source; do
    state=$(self__state "$kind" "$target" "$source" "$expected")
    if [[ $state == ok || $state == outdated ]]; then
      ours+=("$target")
      names+=("$name")
    fi
  done < <(self__items)

  if ((${#ours[@]} == 0)); then
    ui_skip "nothing to remove"
    return 0
  fi
  ui_header "Will remove: ${names[*]}"
  ui_note "Your settings, history and logs in ~/.config/devctl and ~/.local/state/devctl are kept."
  confirm_or_abort "Remove ${#ours[@]} devctl file(s)?"
  for target in "${ours[@]}"; do
    run_change --desc "Remove" -- rm -f -- "$target" || die "$EX_EXTERNAL" "could not remove $target"
  done
  self__refresh_caches
  ui_ok "devctl removed for $USER (the repo itself is untouched)"
}

complete_self() {
  [[ $1 == flags && $2 == install ]] && printf '%s\n' --force --no-desktop-icon
  return 0
}

help_self() {
  cat <<'HELP'
Usage: devctl self [status]                         what is installed, and where
       devctl self install [--force] [--no-desktop-icon]
       devctl self uninstall

Installs devctl for your user only (no sudo), all pointing into this repository:
  command      ~/.local/bin/devctl              → bin/devctl
  completion   ~/.local/share/bash-completion/completions/devctl
  icon         ~/.local/share/icons/hicolor/scalable/apps/devctl.svg
  app-launcher ~/.local/share/applications/devctl-dashboard.desktop
  desktop-icon ~/Desktop/devctl-dashboard.desktop   (setting self.desktop_icon)

Safe to run again at any time. Files not made by devctl are never replaced unless you
pass --force, which asks first and keeps a .devctl-backup copy.
./install.sh in the repository runs `devctl self install`.
HELP
}
