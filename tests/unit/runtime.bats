#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  router__load_command runtime
}

helper_fn() { bash -c 'source "$1"; logger() { :; }; shift; "$@"' _ "$REPO_ROOT/libexec/devctl-root" "$@"; }

@test "status works with nothing installed (json)" {
  run devctl --json runtime status
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.runtimes | length == 4'
  echo "$output" | jq -e '.shell == "missing"'
}

@test "setup plan lists packages once, through the helper" {
  rt_php_state() { echo missing; }
  rt_php_missing_extensions() { echo php-sodium; }
  rt_node_state() { echo ok; }
  rt_java_state() { echo "JDK missing"; }
  rt_python_state() { echo "uv missing"; }
  priv_run() { echo "PRIV $*"; }
  DEVCTL_DRY_RUN=1
  run cmd_runtime_setup all
  [[ $output == *"PRIV --desc Install packages pkg-install php-fpm php-sodium java-25-openjdk-devel uv"* ]]
  [[ $output == *"PRIV --desc Add devctl's PHP-FPM pool php-fpm-setup"* ]]
}

@test "setup: nothing to do when everything is ok" {
  for rt in php node java python shell; do eval "rt_${rt}_state() { echo ok; }"; done
  run cmd_runtime_setup all
  [[ $output == *"runtimes are set up"* ]]
}

@test "setup: unknown runtime is a usage error" {
  run cmd_runtime_setup ruby
  [ "$status" -eq 2 ]
}

@test "fnm: checksum mismatch installs nothing" {
  curl() { local out; while (($#)); do [[ $1 == -o ]] && out=$2; shift; done; echo "not fnm" >"$out"; }
  run rt__install_fnm
  [ "$status" -eq 9 ]
  [[ $output == *"checksum mismatch"* ]]
  [ ! -e "$HOME/.local/bin/fnm" ]
}

@test "fnm: pinned version and an https-only download" {
  [[ $FNM_URL == https://github.com/Schniz/fnm/releases/download/v$FNM_VERSION/fnm-linux.zip ]]
  [[ $FNM_SHA256 =~ ^[0-9a-f]{64}$ ]]
  grep -q -- "--proto '=https'" "$REPO_ROOT/lib/cmd/runtime.sh"
}

@test "shell file: written once, marked, never overwrites a foreign file" {
  echo 'for rc in ~/.bashrc.d/*; do . "$rc"; done' >"$HOME/.bashrc"
  rt__write_shell_file
  grep -q 'Managed by devctl' "$HOME/.bashrc.d/devctl.sh"
  grep -q 'fnm" env --use-on-cd' "$HOME/.bashrc.d/devctl.sh"
  grep -q 'NODE_EXTRA_CA_CERTS' "$HOME/.bashrc.d/devctl.sh"
  [ "$(stat -c %a "$HOME/.bashrc.d/devctl.sh")" = 600 ]
  bash -n "$HOME/.bashrc.d/devctl.sh"
  echo "mine" >"$HOME/.bashrc.d/devctl.sh"
  run rt__write_shell_file
  [ "$status" -eq 5 ]
  [ "$(cat "$HOME/.bashrc.d/devctl.sh")" = mine ]
}

@test "helper: php-fpm verbs take no arguments" {
  for verb in verb_php_fpm_setup verb_php_fpm_start verb_php_fpm_stop; do
    run helper_fn "$verb" extra
    [ "$status" -eq 64 ] || { echo "$verb accepted an argument"; return 1; }
  done
}

@test "the FPM socket path is one the web server templates accept" {
  adapter_load web
  web_render php t t.test on /tmp - "$RT_FPM_SOCKET"
  grep -q "php_fastcgi unix/$RT_FPM_SOCKET" "$HOME/.local/share/devctl/caddy/sites/t.caddy"
}

@test "PHP without sodium is reported and the setup plans php-sodium" {
  php() { [[ $1 == -m ]] && printf '%s\n' Core json mbstring || command php "$@"; }
  [[ $(rt_php_missing_extensions) == php-sodium ]]
  [ -x /usr/sbin/php-fpm ] || skip "php-fpm not installed here"
  [[ $(rt_php_state) == "extensions missing: php-sodium" ]]
  priv_run() { echo "PRIV $*"; }
  rt_node_state() { echo ok; }; rt_java_state() { echo ok; }; rt_python_state() { echo ok; }; rt_shell_state() { echo ok; }
  DEVCTL_ASSUME_YES=1
  run cmd_runtime_setup php
  [[ $output == *"PRIV --desc Install packages pkg-install php-sodium"* ]]
  [[ $output != *php-fpm-setup* ]]
}

@test "helper: php-sodium is allowed; Caddy validation is quiet on success" {
  grep -q ' php-sodium ' "$REPO_ROOT/libexec/devctl-root"
  grep -q '((rc == 0)) || printf' "$REPO_ROOT/libexec/devctl-root"
}
