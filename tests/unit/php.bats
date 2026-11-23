#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  source "$REPO_ROOT/lib/services/php.sh"
  php_system_version() { echo 8.5; }
}

helper_fn() { bash -c 'source "$1"; logger() { :; }; shift; "$@"' _ "$REPO_ROOT/libexec/devctl-root" "$@"; }

@test "paths per version: system vs Remi" {
  [ "$(php_bin 8.5)" = /usr/bin/php ] && [ "$(php_bin 8.4)" = /usr/bin/php84 ]
  [ "$(php_fpm_socket 8.5)" = /run/php-fpm/devctl.sock ]
  [ "$(php_fpm_socket 8.4)" = /var/opt/remi/php84/run/php-fpm/devctl.sock ]
  [ "$(php_fpm_unit 8.4)" = php84-php-fpm.service ]
  [ -z "$(php_helper_arg 8.5)" ] && [ "$(php_helper_arg 8.4)" = 8.4 ]
}

@test "choose: newest version whose platform check passes; none → empty" {
  local p="$BATS_TEST_TMPDIR/proj"; mkdir -p "$p"; echo '{}' >"$p/composer.lock"
  php_versions() { printf '%s\n' 8.5 8.4; }
  php_composer() { [[ $1 == 8.4 ]]; }          # only 8.4 satisfies the lock
  [ "$(php_choose_for "$p")" = 8.4 ]
  php_composer() { return 1; }
  [ -z "$(php_choose_for "$p")" ]
  rm "$p/composer.lock"
  [ "$(php_choose_for "$p")" = 8.5 ]         # no lock: the default
}

@test "web config accepts Remi's FPM socket, nothing else under /var" {
  adapter_load web
  web_render php t t.test on /tmp - /var/opt/remi/php84/run/php-fpm/devctl.sock
  grep -q 'php_fastcgi unix//var/opt/remi/php84/run/php-fpm/devctl.sock' "$HOME/.local/share/devctl/caddy/sites/t.caddy"
  run web_render php t t.test on /tmp - /var/lib/evil.sock
  [ "$status" -eq 1 ]
}

@test "helper: version paths, accepted versions" {
  helper_fn valid_php_version 8.4
  ! helper_fn valid_php_version 8.5
  ! helper_fn valid_php_version 7.4
  ! helper_fn valid_php_version '8.4;rm'
  [ "$(helper_fn bash -c 'fpm__paths 8.4; echo "$FPM_POOL|$FPM_SOCKET|$FPM_BIN|$FPM_UNIT"' 2>/dev/null || true)" != x ]
  run helper_fn verb_php_version_install 7.4
  [ "$status" -eq 64 ]
  run helper_fn verb_php_fpm_start 9.9
  [ "$status" -eq 64 ]
}

@test "helper: Remi release pinned by checksum and key fingerprint, Fedora 44 only" {
  grep -q '^readonly REMI_RELEASE_URL=https://rpms.remirepo.net/fedora/remi-release-44.rpm$' "$REPO_ROOT/libexec/devctl-root"
  grep -qE '^readonly REMI_RELEASE_SHA256=[0-9a-f]{64}$' "$REPO_ROOT/libexec/devctl-root"
  grep -q '^readonly REMI_KEY_FPR=2E375FE24EDFF0F2E0D8E165ED5B58C5BEFA00E2$' "$REPO_ROOT/libexec/devctl-root"
  grep -q 'fedora 44' "$REPO_ROOT/libexec/devctl-root"
}

@test "site php: unknown site, not set up version, non-PHP site" {
  run devctl site php nope
  [ "$status" -eq 4 ]
  source "$REPO_ROOT/lib/services/sites.sh"
  site__save api name=api category=elden path=/x domain=api.test kind=proxy tls=on
  run devctl site php api 8.4
  [ "$status" -eq 2 ]
  site__save shop name=shop category=elden path=/x domain=shop.test kind=laravel tls=on
  run devctl site php shop 8.1
  [ "$status" -eq 7 ] && [[ $output == *"devctl runtime php add 8.1"* ]]
}

@test "runtime php add: version checks and dry-run plan" {
  run devctl runtime php add 7.4
  [ "$status" -eq 2 ]
  run devctl --dry-run --yes runtime php add 8.3
  [[ $output == *"php-version-install 8.3"* && $output == *"php-fpm-setup 8.3"* ]]
}

@test "helper: SELinux rules only where the policy's label is wrong; refuses an unconfined FPM" {
  grep -q 'matchpathcon -n -- "$path"' "$REPO_ROOT/libexec/devctl-root"
  grep -q 'it would run unconfined' "$REPO_ROOT/libexec/devctl-root"
}
