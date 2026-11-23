#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  ( umask 077; mkdir -p "$DEVCTL_DATA_DIR/registry" )
  source "$REPO_ROOT/lib/services/sites.sh"
}

# A gh stand-in: signed in as "me", member of org "elden-co", one repo each.
fake_gh() {
  local dir="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$dir"
  cat >"$dir/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >>"$BATS_TEST_TMPDIR/gh.log"
case "$1 $2" in
  "auth status") exit ${GH_LOGGED_OUT:-0} ;;
  "api user") echo me ;;
  "api user/orgs") echo elden-co ;;
  "api graphql")
    echo "graphql" >>"$BATS_TEST_TMPDIR/graphql.count"
    cat <<'JSON'
[{"data":{"viewer":{"repositories":{"nodes":[
 {"nameWithOwner":"me/blog","description":null,"isPrivate":false,"pushedAt":"2026-10-01T00:00:00Z","url":"https://github.com/me/blog","primaryLanguage":{"name":"PHP"}},
 {"nameWithOwner":"elden-co/crm","description":"CRM","isPrivate":true,"pushedAt":"2026-11-01T00:00:00Z","url":"https://github.com/elden-co/crm","primaryLanguage":{"name":"Java"}}],
 "pageInfo":{"hasNextPage":true,"endCursor":"x"}}}}},
 {"data":{"viewer":{"repositories":{"nodes":[
 {"nameWithOwner":"other/lib","description":"","isPrivate":false,"pushedAt":"2026-09-01T00:00:00Z","url":"https://github.com/other/lib","primaryLanguage":null}],
 "pageInfo":{"hasNextPage":false,"endCursor":null}}}}}]
JSON
    ;;
  "repo list")
    case "$3" in
      me) echo '[{"nameWithOwner":"me/blog","description":null,"primaryLanguage":{"name":"PHP"},"isPrivate":false,"pushedAt":"2026-10-01T00:00:00Z","url":"https://github.com/me/blog"}]' ;;
      elden-co) echo '[{"nameWithOwner":"elden-co/crm","description":"CRM","primaryLanguage":{"name":"Java"},"isPrivate":true,"pushedAt":"2026-11-01T00:00:00Z","url":"https://github.com/elden-co/crm"}]' ;;
    esac ;;
esac
STUB
  chmod +x "$dir/gh"
  export PATH="$dir:$PATH" BATS_TEST_TMPDIR
}

@test "repos: one query over all pages (owner, collaborator, organisations), newest push first" {
  fake_gh
  run devctl --json github repos
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 3 and .[0].repo == "elden-co/crm" and .[0].private == true and .[1].repo == "me/blog" and .[2].language == ""'
  run devctl github repos --owner 'bad owner!'
  [ "$status" -eq 3 ]
  run devctl --json github repos --owner ME
  echo "$output" | jq -e 'length == 1 and .[0].repo == "me/blog"'
}

@test "repos are cached privately for 15 minutes; --refresh asks GitHub again; --cached never does" {
  fake_gh
  devctl --json github repos >/dev/null
  devctl --json github repos >/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/graphql.count")" -eq 1 ]
  [ "$(stat -c %a "$HOME/.cache/devctl/github-repos.json")" = 600 ]
  devctl --json github repos --refresh >/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/graphql.count")" -eq 2 ]
  touch -d '20 minutes ago' "$HOME/.cache/devctl/github-repos.json"
  devctl --json github repos --cached >/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/graphql.count")" -eq 2 ]
  devctl --json github repos >/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/graphql.count")" -eq 3 ]
  rm "$HOME/.cache/devctl/github-repos.json"
  run devctl --json github repos --cached
  [ "$status" -eq 4 ]
}

@test "repos: signed out → clear message" {
  fake_gh
  GH_LOGGED_OUT=1 run devctl github repos
  [ "$status" -eq 7 ] && [[ $output == *"devctl github setup"* ]]
}

@test "status json" {
  fake_gh
  run devctl --json github status
  echo "$output" | jq -e '.gh_installed and .logged_in and .user == "me"'
}

@test "repository sources: OWNER/REPO → GitHub URL; unsafe input refused" {
  [ "$(site__repo_url me/blog)" = https://github.com/me/blog.git ]
  [ "$(site__repo_url me/blog.git)" = https://github.com/me/blog.git ]
  [ "$(site__repo_url https://gitlab.com/x/y.git)" = https://gitlab.com/x/y.git ]
  run site__repo_url 'me/blog; rm -rf ~'
  [ "$status" -eq 3 ]
  run site__repo_url 'file:///etc'
  [ "$status" -eq 3 ]
  run site__repo_url '--upload-pack=x'
  [ "$status" -eq 3 ]
}

@test "detection: Laravel, Spring Boot (Maven and Gradle), plain Java, static, unknown" {
  local d="$BATS_TEST_TMPDIR"
  mkdir -p "$d/l" "$d/sm" "$d/sg" "$d/j/src/x" "$d/s" "$d/u" "$d/mvn/src"
  echo '{"require": {"laravel/framework": "^13.0"}}' >"$d/l/composer.json"
  echo '<parent><artifactId>spring-boot-starter-parent</artifactId></parent>' >"$d/sm/pom.xml"
  echo 'plugins { id("org.springframework.boot") version "4.1.2" }' >"$d/sg/build.gradle.kts"
  echo 'class A {}' >"$d/j/src/x/A.java"
  echo '<p>hi' >"$d/s/index.html"
  echo '<project/>' >"$d/mvn/pom.xml"; echo 'class B {}' >"$d/mvn/src/B.java"
  [ "$(site__detect "$d/l")" = "laravel -" ]
  [ "$(site__detect "$d/sm")" = "proxy spring-boot" ]
  [ "$(site__detect "$d/sg")" = "proxy spring-boot" ]
  [ "$(site__detect "$d/j")" = "none java" ]
  [ "$(site__detect "$d/s")" = "static -" ]
  [ -z "$(site__detect "$d/u")" ]
  [ -z "$(site__detect "$d/mvn")" ]       # Maven without Spring: not guessed
}

@test "clone uses gh when signed in (private repos), git otherwise" {
  fake_gh
  DEVCTL_DRY_RUN=1
  run site_clone me/blog blog personal
  [[ $output == *"Clone (gh): gh repo clone https://github.com/me/blog.git $HOME/Desktop/projects/personal/blog"* ]]
  GH_LOGGED_OUT=1 run site_clone me/blog blog personal
  [[ $output == *"Clone: git clone -- https://github.com/me/blog.git"* ]]
}

@test "CLI clone: name derived from the repository" {
  run devctl --dry-run --yes site clone Me/My_Cool.Repo --category personal
  [[ $output == *"using the name 'my-cool-repo'"* ]]
}

@test "login --with-token: token from stdin only, shape checked, never echoed" {
  fake_gh
  GH_LOGGED_OUT=1 run bash -c "printf 'hunter2\n' | '$REPO_ROOT/bin/devctl' github login --with-token"
  [ "$status" -eq 3 ] && [[ $output != *hunter2* ]]
  local token="ghp_$(printf 'A%.0s' {1..36})"
  GH_LOGGED_OUT=1 run bash -c "printf '%s\n' '$token' | '$REPO_ROOT/bin/devctl' github login --with-token"
  [[ $output != *"$token"* ]]
  grep -q '^gh auth login --hostname github.com --git-protocol https --with-token$' "$BATS_TEST_TMPDIR/gh.log"
  ! grep -q "$token" "$BATS_TEST_TMPDIR/gh.log"            # not in gh's arguments
  ! grep -rq "$token" "$HOME/.local/state/devctl"          # not in logs or history
}

@test "identity: validated, then git config --global (dry-run shows it)" {
  run devctl github identity --name "" --email a@b.co
  [ "$status" -eq 3 ]
  run devctl github identity --name "Me" --email "bad"
  [ "$status" -eq 3 ]
  run devctl --dry-run github identity --name "Zaitoune M" --email me@example.com
  [[ $output == *"git config --global user.name Zaitoune\ M"* && $output == *"git config --global user.email me@example.com"* ]]
}
