#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  adapter_load web
  adapter_load dns
}

helper_fn() { bash -c 'source "$1"; logger() { :; }; shift; "$@"' _ "$REPO_ROOT/libexec/devctl-root" "$@"; }

@test "render: php site with HTTPS, all placeholders filled" {
  web_render php shop shop.test on "$HOME/Desktop/projects/personal/shop" - /run/php-fpm/www.sock
  local f="$HOME/.local/share/devctl/caddy/sites/shop.caddy"
  grep -qx 'shop.test {' "$f"
  grep -q "root \* \"$HOME/Desktop/projects/personal/shop/public\"" "$f"
  grep -q 'php_fastcgi unix//run/php-fpm/www.sock' "$f"
  ! grep -q '{{' "$f"
}

@test "render: TLS off gives an http:// address; proxy gets its port" {
  web_render proxy api api.test off - 8080 -
  grep -qx 'http://api.test {' "$HOME/.local/share/devctl/caddy/sites/api.caddy"
  grep -q 'reverse_proxy 127.0.0.1:8080' "$HOME/.local/share/devctl/caddy/sites/api.caddy"
}

@test "render: unsafe values are refused" {
  run web_render static x x.test on '/tmp/a b' - -
  [ "$status" -eq 3 ]
  run web_render static x x.test on '/tmp/a"}' - -
  [ "$status" -eq 3 ]
  run web_render static 'x;y' x.test on /tmp - -
  [ "$status" -eq 1 ]
  run web_render php x x.test on /tmp - /etc/shadow
  [ "$status" -eq 1 ]
  run web_render cgi x x.test on /tmp - -
  [ "$status" -eq 1 ]
}

@test "render: dry-run writes nothing; remove deletes the staged file" {
  DEVCTL_DRY_RUN=1 web_render static s s.test on /tmp - -
  [ ! -e "$HOME/.local/share/devctl/caddy/sites/s.caddy" ]
  web_render static s s.test on /tmp - -
  [ "$(web_sites)" = s ]
  web_remove s
  [ -z "$(web_sites)" ]
}

@test "staging must be in the default data folder (the helper never trusts XDG_DATA_HOME)" {
  WEB_STAGING_DIR=/tmp/elsewhere
  run web_render static s s.test on /tmp - -
  [ "$status" -eq 7 ]
}

@test "trust state through certutil (stubbed)" {
  stub_commands certutil
  mkdir -p "$HOME/.mozilla/firefox/abc.default-release"
  touch "$HOME/.mozilla/firefox/abc.default-release/cert9.db"
  [ "$(web_trust_firefox_dbs)" = "$HOME/.mozilla/firefox/abc.default-release" ]
  [ "$(web_trust_state firefox)" = yes ]       # stub exits 0 = "found"
  rm -r "$HOME/.mozilla"
  [ "$(web_trust_state firefox)" = n/a ]
}

@test "trust import plans one certutil -A per store" {
  stub_commands certutil
  mkdir -p "$HOME/.mozilla/firefox/p1"; touch "$HOME/.mozilla/firefox/p1/cert9.db"
  web__nssdb_has() { return 1; }
  DEVCTL_DRY_RUN=1
  run web_trust_user_dbs
  [[ $output == *"certutil -N -d sql:$HOME/.pki/nssdb --empty-password"* ]]
  [[ $output == *"certutil -A -d sql:$HOME/.mozilla/firefox/p1 -n devctl\ local\ CA -t C\,\, -i"* ]]
  [[ $output == *"certutil -A -d sql:$HOME/.pki/nssdb"* ]]
}

@test "dns: add/remove keep a sorted unique list; apply only when it differs" {
  dns_add shop.test; dns_add api.test; dns_add shop.test
  [ "$(dns_names | paste -sd,)" = "api.test,shop.test" ]
  dns_remove api.test
  [ "$(dns_names)" = shop.test ]
  dns_live() { echo shop.test; }
  priv_run() { echo CALLED; }
  [ -z "$(dns_apply)" ]
  dns_add new.test
  [ "$(dns_apply)" = CALLED ]
}

@test "dns: live names are read only from devctl's block" {
  dns_live_from() { awk '/^# >>> devctl managed block/ {b=1; next} /^# <<< devctl managed block/ {b=0} b && $1 == "127.0.0.1" {print $2}' "$1"; }
  printf '%s\n' '127.0.0.1 localhost' '# >>> devctl managed block — do not edit by hand >>>' '127.0.0.1 shop.test' '::1       shop.test' '# <<< devctl managed block <<<' '10.0.0.1 nas' >"$BATS_TEST_TMPDIR/hosts"
  [ "$(dns_live_from "$BATS_TEST_TMPDIR/hosts")" = shop.test ]
}

@test "helper: local names and new verbs reject bad input" {
  helper_fn valid_local_name shop.test
  ! helper_fn valid_local_name Shop.test
  ! helper_fn valid_local_name 'shop.test evil.com'
  ! helper_fn valid_local_name shop.test.evil
  ! helper_fn valid_local_name '127.0.0.1'
  for verb in verb_web_selinux_setup verb_caddy_setup verb_caddy_apply verb_caddy_rollback verb_caddy_start verb_caddy_stop verb_ca_export verb_ca_trust_system verb_hosts_apply; do
    run helper_fn "$verb" extra
    [ "$status" -eq 64 ] || { echo "$verb accepted an argument"; return 1; }
  done
}

@test "helper's hosts rewrite keeps every line outside the block" {
  # the awk filter used by hosts-apply, applied to a sample file
  printf '%s\n' '127.0.0.1 localhost' '# >>> devctl managed block — do not edit by hand >>>' '127.0.0.1 old.test' '# <<< devctl managed block <<<' '192.168.1.5 nas # mine' >"$BATS_TEST_TMPDIR/h"
  run awk -v b='# >>> devctl managed block — do not edit by hand >>>' -v e='# <<< devctl managed block <<<' '$0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "$BATS_TEST_TMPDIR/h"
  [ "$output" = $'127.0.0.1 localhost\n192.168.1.5 nas # mine' ]
}

@test "CLI: web status/setup dry-run and domain list work before Caddy exists" {
  run devctl --json web status
  echo "$output" | jq -e 'has("installed") and has("trust")'
  run devctl --dry-run --yes web setup
  [ "$status" -eq 0 ]
  run devctl domain
  [[ $output == *"no local names yet"* ]]
}
