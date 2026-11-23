# shellcheck shell=bash
# BATS_* variables are provided by bats at runtime.
# shellcheck disable=SC2154
# Shared setup for bats tests. Every test gets a private, empty HOME, so nothing
# touches the real ~/.config, ~/.local or the system.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup_home() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME NO_COLOR DEVCTL_SOURCE WAYLAND_DISPLAY DISPLAY
  local var
  for var in $(compgen -e DEVCTL_CFG_ || true); do unset "$var"; done
  export TMPDIR="$BATS_TEST_TMPDIR"
}

# load_core — source the core libraries into the test shell (no strict mode, no traps).
load_core() {
  export DEVCTL_ROOT="$REPO_ROOT"
  # shellcheck source=lib/core/bootstrap.sh
  source "$REPO_ROOT/lib/core/bootstrap.sh"
  config_load
}

# make_sandbox — copy the repo into the test dir and print its path, so tests can add
# fake command files without touching the real lib/cmd.
make_sandbox() {
  local dir="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$dir"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/share" "$dir/"
  printf '%s\n' "$dir"
}

devctl() { "$REPO_ROOT/bin/devctl" "$@"; }

write_user_config() {
  mkdir -p "$HOME/.config/devctl"
  printf '%s\n' "$@" >"$HOME/.config/devctl/devctl.conf"
  chmod 600 "$HOME/.config/devctl/devctl.conf"
}

# stub_commands NAME... — put fake commands first in PATH that just log their arguments
# to $BATS_TEST_TMPDIR/stub.log (used for gio, cache updaters, systemctl, …).
stub_commands() {
  local dir="$BATS_TEST_TMPDIR/stubs" name
  mkdir -p "$dir"
  for name; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/stub.log"\n' "$name" "$BATS_TEST_TMPDIR" >"$dir/$name"
    chmod +x "$dir/$name"
  done
  export PATH="$dir:$PATH"
}
