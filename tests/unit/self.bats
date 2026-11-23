#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  stub_commands gio update-desktop-database gtk-update-icon-cache
}

@test "dry run changes nothing" {
  run devctl --dry-run self install
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] Link command"* ]]
  [ ! -e "$HOME/.local/bin/devctl" ]
  [ ! -e "$HOME/.local/state/devctl/history.jsonl" ] || ! grep -q '"result":"ok"' "$HOME/.local/state/devctl/history.jsonl"
}

@test "install creates links and launchers; second run changes nothing" {
  run devctl self install
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/devctl")" = "$REPO_ROOT/bin/devctl" ]
  [ "$(readlink "$HOME/.local/share/bash-completion/completions/devctl")" = "$REPO_ROOT/share/completions/devctl.bash" ]
  [ -L "$HOME/.local/share/icons/hicolor/scalable/apps/devctl.svg" ]
  grep -qx "Exec=$REPO_ROOT/bin/devctl dashboard" "$HOME/.local/share/applications/devctl-dashboard.desktop"
  [ "$(stat -c %a "$HOME/Desktop/devctl-dashboard.desktop")" = 755 ]
  grep -q "gio set -- $HOME/Desktop/devctl-dashboard.desktop metadata::trusted true" "$BATS_TEST_TMPDIR/stub.log"
  "$HOME/.local/bin/devctl" version
  run devctl self install
  [[ $output == *"command: already installed"* && $output == *"desktop-icon: already installed"* ]]
  [ "$(devctl --json self status | jq -r '[.[].state] | unique | join(",")')" = ok ]
}

@test "foreign files are never replaced without --force" {
  mkdir -p "$HOME/.local/bin"
  echo "someone else's script" >"$HOME/.local/bin/devctl"
  run devctl self install
  [ "$status" -eq 5 ]
  [[ $output == *"not made by devctl"* ]]
  [ "$(cat "$HOME/.local/bin/devctl")" = "someone else's script" ]
  # the other items were still installed
  [ -L "$HOME/.local/share/bash-completion/completions/devctl" ]
}

@test "--force backs up the foreign file after confirmation" {
  mkdir -p "$HOME/.local/bin"
  echo "old" >"$HOME/.local/bin/devctl"
  run devctl --yes self install --force
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/bin/devctl" ]
  [ "$(cat "$HOME/.local/bin/devctl.devctl-backup")" = old ]
}

@test "hand-installed earlier copies are recognised and updated" {
  mkdir -p "$HOME/.local/share/icons/hicolor/scalable/apps" "$HOME/Desktop"
  cp "$REPO_ROOT/share/icons/devctl.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/devctl.svg"
  printf '[Desktop Entry]\nExec=%s dashboard\n' "$REPO_ROOT/bin/devctl" >"$HOME/Desktop/devctl-dashboard.desktop"
  run devctl --json self status
  echo "$output" | jq -e '.[] | select(.item == "icon" or .item == "desktop-icon") | .state == "outdated"'
  devctl self install
  [ -L "$HOME/.local/share/icons/hicolor/scalable/apps/devctl.svg" ]
  grep -qx 'X-Devctl-Managed=true' "$HOME/Desktop/devctl-dashboard.desktop"
}

@test "self.desktop_icon = false skips the desktop launcher" {
  write_user_config 'self.desktop_icon = false'
  devctl self install
  [ ! -e "$HOME/Desktop/devctl-dashboard.desktop" ]
  [ -e "$HOME/.local/share/applications/devctl-dashboard.desktop" ]
}

@test "Desktop folder comes from user-dirs.dirs" {
  mkdir -p "$HOME/.config"
  echo 'XDG_DESKTOP_DIR="$HOME/Bureau"' >"$HOME/.config/user-dirs.dirs"
  devctl self install
  [ -e "$HOME/Bureau/devctl-dashboard.desktop" ]
}

@test "uninstall removes only devctl's files, after confirmation" {
  devctl self install
  echo "mine" >"$HOME/Desktop/notes.txt"
  run devctl self uninstall </dev/null
  [ "$status" -eq 7 ]                        # needs a terminal or --yes
  devctl --yes self uninstall
  [ ! -e "$HOME/.local/bin/devctl" ] && [ ! -e "$HOME/Desktop/devctl-dashboard.desktop" ]
  [ -e "$HOME/Desktop/notes.txt" ]
  run devctl self uninstall
  [[ $output == *"nothing to remove"* ]]
}

@test "install and uninstall are recorded in history" {
  devctl self install
  devctl --yes self uninstall
  [ "$(jq -r .action "$HOME/.local/state/devctl/history.jsonl" | paste -sd,)" = "self.install,self.uninstall" ]
}

@test "install.sh runs self install and passes flags" {
  run "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] Link command"* ]]
}
