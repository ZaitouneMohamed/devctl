#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  ( umask 077; mkdir -p "$DEVCTL_DATA_DIR/registry" )
  source "$REPO_ROOT/lib/services/sites.sh"
  ss() { :; }
}

@test "every template has a complete template.conf and a create.sh with tpl_create" {
  local t
  local -A tpl=()
  for t in $(cd "$REPO_ROOT/templates/projects" && ls */template.conf | cut -d/ -f1); do
    site__template_load "$t" tpl
    [[ -n ${tpl[name]} && -n ${tpl[description]} ]]
    is_in_list "${tpl[kind]}" laravel static proxy none
    declare -F tpl_create >/dev/null
    bash -n "$REPO_ROOT/templates/projects/$t/create.sh"
  done
}

@test "templates do not leak functions into each other" {
  local -A tpl=()
  site__template_load spring-boot tpl
  declare -F tpl_configure >/dev/null
  site__template_load static tpl
  ! declare -F tpl_configure >/dev/null
  ! declare -F tpl_dev >/dev/null
}

@test "static: files copied, name filled in" {
  local -A tpl=()
  site__template_load static tpl
  tpl_create "$BATS_TEST_TMPDIR/web" web
  grep -q '<title>web</title>' "$BATS_TEST_TMPDIR/web/index.html"
  [ -f "$BATS_TEST_TMPDIR/web/css/style.css" ] && [ -f "$BATS_TEST_TMPDIR/web/js/main.js" ]
}

@test "plain Java: .java-version and sources; dev compiles and runs with the project's JDK" {
  local -A tpl=()
  site__template_load java tpl
  tpl_create "$BATS_TEST_TMPDIR/algo" algo
  [ "$(cat "$BATS_TEST_TMPDIR/algo/.java-version")" = 25 ]
  [[ -x /usr/lib/jvm/java-25-openjdk/bin/javac ]] || skip "JDK 25 not installed"
  run tpl_dev "$BATS_TEST_TMPDIR/algo" algo
  [ "$output" = "Hello from algo on Java 25" ]
}

@test "Java version file is validated" {
  mkdir -p "$BATS_TEST_TMPDIR/p"
  echo '25; rm -rf /' >"$BATS_TEST_TMPDIR/p/.java-version"
  run site__java_version "$BATS_TEST_TMPDIR/p"
  [ "$status" -eq 3 ]
  echo 21 >"$BATS_TEST_TMPDIR/p/.java-version"
  [ "$(site__java_home "$BATS_TEST_TMPDIR/p")" = /usr/lib/jvm/java-21-openjdk ]
}

@test "Spring Boot: dependencies follow the database; settings in a private, git-ignored file" {
  local -A tpl=()
  site__template_load spring-boot tpl
  DEVCTL_DRY_RUN=1
  run tpl_create "$BATS_TEST_TMPDIR/api" api mysql
  [[ $output == *"web,validation,devtools,data-jpa,mysql"* ]]
  run tpl_create "$BATS_TEST_TMPDIR/api" api none
  [[ $output == *"(maven, java 25, web,validation,devtools)"* ]]
  DEVCTL_DRY_RUN=0
  mkdir -p "$BATS_TEST_TMPDIR/api"
  tpl_configure "$BATS_TEST_TMPDIR/api" api postgres 5432 api api Pw123
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/api/devctl.env")" = 600 ]
  grep -qx 'SPRING_DATASOURCE_URL=jdbc:postgresql://127.0.0.1:5432/api' "$BATS_TEST_TMPDIR/api/devctl.env"
}

@test "Spring Boot dev passes only safe KEY=value lines from devctl.env, binds to 127.0.0.1" {
  local -A tpl=()
  site__template_load spring-boot tpl
  mkdir -p "$BATS_TEST_TMPDIR/api"
  printf '%s\n' 'SPRING_DATASOURCE_URL=jdbc:mysql://127.0.0.1:3306/api' 'EVIL=$(rm -rf ~)' 'lower=x' >"$BATS_TEST_TMPDIR/api/devctl.env"
  printf '#!/bin/sh\nenv | sort\n' >"$BATS_TEST_TMPDIR/api/mvnw"; chmod +x "$BATS_TEST_TMPDIR/api/mvnw"
  site__java_home() { printf '/usr\n'; }   # any java for the version check
  [[ -x /usr/bin/java ]] || skip "java not installed"
  run tpl_dev "$BATS_TEST_TMPDIR/api" api 8100
  [[ $output == *"SERVER_ADDRESS=127.0.0.1"* && $output == *"SERVER_PORT=8100"* ]]
  [[ $output == *"SPRING_DATASOURCE_URL=jdbc:mysql://127.0.0.1:3306/api"* ]]
  [[ $output != *"EVIL="* && $output != *"lower=x"* ]]
}

@test "app ports for proxied apps come from 8100-8199 and are kept" {
  [ "$(site__app_port_allocate api)" = 8100 ]
  [ "$(site__app_port_allocate web2)" = 8101 ]
  grep -q $'^8100\tapp-api' "$DB_PORTS_FILE"
}

@test "kinds: proxy sites only forward (no SELinux/ACL); plain Java has no website" {
  site__save api name=api category=personal path="$HOME/p/api" domain=api.test kind=proxy tls=on app_port=8100 template=spring-boot
  priv_run() { echo "PRIV $*"; }
  dns_apply() { :; }; web_apply() { :; }; web_start() { :; }
  run site__serve api
  [[ $output != *project-label* ]]
  grep -q 'reverse_proxy 127.0.0.1:8100' "$HOME/.local/share/devctl/caddy/sites/api.caddy"
  site__save algo name=algo category=school path="$HOME/p/algo" domain= kind=none tls=on template=java
  run site__serve algo
  [ -z "$output" ]
  [ ! -e "$HOME/.local/share/devctl/caddy/sites/algo.caddy" ]
}

@test "CLI: templates list; database rules per template" {
  run devctl site templates
  [[ $output == *spring-boot* && $output == *static* && $output == *java* ]]
  run devctl site create web1 --template static --category personal --db mysql
  [ "$status" -eq 3 ] && [[ $output == *"has no database"* ]]
  run devctl site create api1 --template spring-boot --category personal --db sqlite
  [ "$status" -eq 3 ]
  run devctl --dry-run --yes site create algo1 --template java --category school
  [ "$status" -eq 0 ] && [[ $output != *"url"* ]]
}

@test "Laravel variants share one implementation; the shared folder is not a template" {
  run devctl site templates
  [[ $output == *laravel-blade* && $output == *laravel-api* && $output != *_laravel* ]]
  local t
  local -A tpl=()
  for t in laravel-inertia-react laravel-blade laravel-api; do
    site__template_load "$t" tpl
    [ "${tpl[kind]}" = laravel ]
    grep -q 'templates/projects/_laravel/laravel.sh' "$REPO_ROOT/templates/projects/$t/create.sh"
  done
}

@test "Laravel packages: starter kit for Inertia, laravel/laravel for Blade and API" {
  local -A tpl=()
  DEVCTL_DRY_RUN=1
  site__template_load laravel-blade tpl
  run tpl_create /tmp/x x mysql
  [[ $output == *"-- laravel/laravel /tmp/x \^13.0"* ]]
  site__template_load laravel-inertia-react tpl
  run tpl_create /tmp/x x mysql
  [[ $output == *"-- laravel/react-starter-kit /tmp/x dev-main"* ]]
}

@test "Laravel API: no Vite port, no npm; HasApiTokens edit on a sample model" {
  local -A tpl=()
  site__template_load laravel-api tpl
  [ "${tpl[vite]}" = no ]
  [ "$LARAVEL_FRONTEND" = no ]
  local p="$BATS_TEST_TMPDIR/api"
  mkdir -p "$p/app/Models" "$p/database/migrations"
  touch "$p/database/migrations/2026_01_01_000000_create_personal_access_tokens_table.php"
  printf '%s\n' '<?php' 'namespace App\Models;' 'use Illuminate\Notifications\Notifiable;' 'class User {' '    use HasFactory, Notifiable;' '}' >"$p/app/Models/User.php"
  run_change() { :; }    # artisan is not available here
  laravel_after_env "$p"
  grep -qx 'use Laravel\\Sanctum\\HasApiTokens;' "$p/app/Models/User.php"
  grep -qx '    use HasApiTokens, HasFactory, Notifiable;' "$p/app/Models/User.php"
  laravel_after_env "$p"     # idempotent
  [ "$(grep -c HasApiTokens "$p/app/Models/User.php")" -eq 2 ]
}
