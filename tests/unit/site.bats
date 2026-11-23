#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  ( umask 077; mkdir -p "$DEVCTL_DATA_DIR/registry" )
  source "$REPO_ROOT/lib/services/sites.sh"
  ss() { :; }
}

@test "names: rules, reserved words, length, categories, uniqueness" {
  site_validate_new shop personal
  run site_validate_new Shop personal;   [ "$status" -eq 3 ]
  run site_validate_new devctl personal; [ "$status" -eq 3 ]
  run site_validate_new mail personal;   [ "$status" -eq 3 ]
  run site_validate_new "$(printf 'a%.0s' {1..33})" personal; [ "$status" -eq 3 ]
  run site_validate_new shop work;       [ "$status" -eq 3 ]
  mkdir -p "$HOME/Desktop/projects/personal/shop"
  run site_validate_new shop personal;   [ "$status" -eq 5 ]
}

@test "paths, domains and database names" {
  [ "$(site_path shop elden)" = "$HOME/Desktop/projects/elden/shop" ]
  [ "$(site_domain shop)" = shop.test ]
  [ "$(site_db_name my-shop)" = my_shop ]
  db_name_valid "$(site_db_name my-shop)"
}

@test "env_set replaces, uncomments and appends; keeps 0600" {
  printf '%s\n' 'APP_URL=http://localhost' 'DB_CONNECTION=sqlite' '# DB_HOST=127.0.0.1' '# DB_PASSWORD=' >"$BATS_TEST_TMPDIR/.env"
  env_set "$BATS_TEST_TMPDIR/.env" APP_URL https://shop.test
  env_set "$BATS_TEST_TMPDIR/.env" DB_HOST 127.0.0.1
  env_set "$BATS_TEST_TMPDIR/.env" DB_PASSWORD Abc123
  env_set "$BATS_TEST_TMPDIR/.env" DB_PORT 3306
  [ "$(cat "$BATS_TEST_TMPDIR/.env")" = $'APP_URL=https://shop.test\nDB_CONNECTION=sqlite\nDB_HOST=127.0.0.1\nDB_PASSWORD=Abc123\nDB_PORT=3306' ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/.env")" = 600 ]
  run env_set "$BATS_TEST_TMPDIR/.env" DB_PASSWORD 'a b'
  [ "$status" -eq 1 ]
}

@test "Vite ports: from the labelled range, recorded, never reused" {
  [ "$(site__vite_port_allocate a)" = 44300 ]
  [ "$(site__vite_port_allocate b)" = 44301 ]
  grep -q $'^44300\tvite-a' "$DB_PORTS_FILE"
}

@test "web config of a Laravel site includes the Vite HTTPS listener" {
  web_render php shop shop.test on "$HOME/p/shop" - /run/php-fpm/devctl.sock 44300
  local f="$HOME/.local/share/devctl/caddy/sites/shop.caddy"
  grep -qx 'shop.test:44300 {' "$f"
  grep -q 'reverse_proxy 127.0.0.1:54300' "$f"
  ! grep -q '{{' "$f"
}

@test "registry save/load/set round trip" {
  site__save shop name=shop category=personal path=/p domain=shop.test kind=laravel tls=on db_server=mysql-8-4
  local -A s=()
  site_load shop s
  [ "${s[db_server]}" = mysql-8-4 ]
  site__set shop tls off
  site_load shop s
  [ "${s[tls]}" = off ] && [ "${s[kind]}" = laravel ]
  [ "$(site_names)" = shop ]
}

@test "ACLs: parents traverse-only, served folder read-only (planned commands)" {
  mkdir -p "$HOME/Desktop/projects/personal/shop/public"
  DEVCTL_DRY_RUN=1
  run site__acl_grant "$HOME/Desktop/projects/personal/shop" "$HOME/Desktop/projects/personal/shop/public"
  [[ $output == *"setfacl -m u:caddy:x -- $HOME/Desktop/projects/personal/shop"* ]]
  [[ $output == *"setfacl -m u:caddy:x -- $HOME/Desktop"* ]]
  [[ $output == *"setfacl -m u:caddy:x -- $HOME"* ]]
  [[ $output == *"setfacl -R -m u:caddy:rX -m d:u:caddy:rX -- $HOME/Desktop/projects/personal/shop/public"* ]]
  [[ $output != *"rX -- $HOME/Desktop/projects/personal/shop"$'\n'* ]]
}

@test "git extras: notify hooks installed, foreign hooks kept, vite file excluded" {
  local p="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$p/.git/hooks" "$p/.git/info"
  echo '#!/bin/sh' >"$p/.git/hooks/post-checkout"
  run site__git_extras "$p"
  grep -q 'Added by devctl' "$p/.git/hooks/post-merge"
  [ "$(cat "$p/.git/hooks/post-checkout")" = '#!/bin/sh' ]
  [[ $output == *"post-checkout hook already exists"* ]]
  grep -qx devctl.vite.config.ts "$p/.git/info/exclude"
}

@test "notify hook only reacts to branch checkouts" {
  sh -n "$REPO_ROOT/templates/git-hooks/devctl-notify"
  grep -q '\[ "$3" = 1 \] || exit 0' "$REPO_ROOT/templates/git-hooks/devctl-notify"
}

@test "delete keeps the folder and the database; start/stop count database users" {
  mkdir -p "$HOME/p/shop"
  site__save shop name=shop category=personal path="$HOME/p/shop" domain=shop.test kind=laravel tls=on db_server=mysql-8-4
  db_server_acquire() { echo "ACQUIRE $*"; }
  db_server_release() { echo "RELEASE $*"; }
  site__serve() { :; }
  web_apply() { echo APPLY; }
  run site_start shop
  [[ $output == *"ACQUIRE mysql-8-4 shop"* ]]
  site_start shop >/dev/null
  site_running shop
  run site_stop shop
  [[ $output == *"RELEASE mysql-8-4 shop"* && $output == *APPLY* ]]
  grep -q 'respond "shop is stopped' "$HOME/.local/share/devctl/caddy/sites/shop.caddy"
  priv_run() { echo "PRIV $*"; }
  web_apply() { :; }
  dns_apply() { :; }
  setfacl() { :; }
  site_delete shop
  ! site_exists shop
  [ -d "$HOME/p/shop" ]
}

@test "CLI: create asks for missing choices only in a terminal; dry-run plans everything" {
  run devctl site create shop --db mysql </dev/null
  [ "$status" -eq 2 ] && [[ $output == *"Category: pass it as an option"* ]]
  run devctl --dry-run --yes site create shop --template laravel-inertia-react --category personal --db postgres
  [ "$status" -eq 0 ]
  [[ $output == *"composer create-project --no-interaction --prefer-dist -- laravel/react-starter-kit $HOME/Desktop/projects/personal/shop dev-main"* ]]
  [ ! -e "$HOME/Desktop/projects/personal" ]
  run devctl site delete nope
  [ "$status" -eq 4 ]
}

@test "the Vite wrapper is valid TypeScript-ish and reads devctl's variables" {
  grep -q "mergeConfig" "$REPO_ROOT/templates/vite/devctl.vite.config.ts"
  for v in DEVCTL_SITE_HOST DEVCTL_VITE_PUBLIC_PORT DEVCTL_VITE_PORT DEVCTL_APP_URL; do
    grep -q "$v" "$REPO_ROOT/templates/vite/devctl.vite.config.ts"
  done
}

@test "server users are markers per site: repeating start/stop never drifts" {
  db_server_start() { :; }
  db_server_stop() { echo "STOPPED $1"; }
  db_server_acquire mysql-8-4 shop
  db_server_acquire mysql-8-4 shop
  db_server_acquire mysql-8-4 blog
  [ "$(db_refcount mysql-8-4)" = 2 ]
  [ "$(db_server_holders mysql-8-4 | paste -sd,)" = "blog,shop" ]
  run db_server_release mysql-8-4 shop
  [ -z "$output" ]
  db_server_release mysql-8-4 shop
  run db_server_release mysql-8-4 blog
  [ "$output" = "STOPPED mysql-8-4" ]
  [ "$(db_refcount mysql-8-4)" = 0 ]
}

@test "an old numeric counter file is ignored and replaced" {
  mkdir -p "$DEVCTL_RUN_DIR/refcount"
  echo 1 >"$DEVCTL_RUN_DIR/refcount/mysql-8-4"
  [ "$(db_refcount mysql-8-4)" = 0 ]
  db_server_start() { :; }
  db_server_acquire mysql-8-4 shop
  [ "$(db_refcount mysql-8-4)" = 1 ]
}
