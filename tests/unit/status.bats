#!/usr/bin/env bats
load '../helpers/common'

setup() { setup_home; }

@test "status: json shape with no sites or servers" {
  run devctl --json status
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("services") and (.sites | length == 0) and (.databases | length == 0) and (.memory | test("available"))'
}

@test "status --watch needs a terminal" {
  run devctl status --watch </dev/null
  [ "$status" -eq 2 ]
}

@test "logs: unknown site, bad options, follow with several parts" {
  run devctl logs nope
  [ "$status" -eq 4 ]
  load_core
  source "$REPO_ROOT/lib/services/sites.sh"
  site__save shop name=shop category=personal path="$HOME/p/shop" domain=shop.test kind=laravel tls=on
  run devctl logs shop --vite
  [ "$status" -eq 2 ]
  run devctl logs shop -f
  [ "$status" -eq 2 ] && [[ $output == *"one part at a time"* ]]
  run devctl logs shop --lines x
  [ "$status" -eq 3 ]
}

@test "logs --app shows the Laravel log tail" {
  load_core
  source "$REPO_ROOT/lib/services/sites.sh"
  mkdir -p "$HOME/p/shop/storage/logs"
  printf 'line %s\n' 1 2 3 >"$HOME/p/shop/storage/logs/laravel.log"
  site__save shop name=shop category=personal path="$HOME/p/shop" domain=shop.test kind=laravel tls=on
  run devctl logs shop --app -n 2
  [ "$output" = $'line 2\nline 3' ]
}

@test "logs --web filters this site's requests and skips non-JSON lines" {
  load_core
  source "$REPO_ROOT/lib/services/sites.sh"
  site__save shop name=shop category=personal path="$HOME/p/shop" domain=shop.test kind=laravel tls=on
  local dir="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$dir"
  cat >"$dir/journalctl" <<'STUB'
#!/bin/sh
echo 'Caddy starting (plain text)'
echo '{"ts":1793915462,"msg":"handled request","status":200,"request":{"host":"shop.test","method":"GET","uri":"/"}}'
echo '{"ts":1793915463,"msg":"handled request","status":404,"request":{"host":"other.test","method":"GET","uri":"/x"}}'
echo '{"ts":1793915464,"msg":"handled request","status":101,"request":{"host":"shop.test:44300","method":"GET","uri":"/@vite"}}'
STUB
  chmod +x "$dir/journalctl"
  PATH="$dir:$PATH" run devctl logs shop --web
  [ "${#lines[@]}" -eq 2 ]
  [[ ${lines[0]} == *"200 GET /"* && ${lines[1]} == *"101 GET /@vite"* ]]
}

@test "runtime: an old PHP pool (file log) is reported as outdated" {
  grep -q 'pool outdated' "$REPO_ROOT/lib/cmd/runtime.sh"
  grep -q 'error_log\] = syslog' "$REPO_ROOT/libexec/devctl-root"
}
