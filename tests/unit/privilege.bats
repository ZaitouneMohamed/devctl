#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
}

# A sudo/pkexec stand-in: logs its argv and exits with $STUB_STATUS (default 0).
fake_launchers() {
  local dir="$BATS_TEST_TMPDIR/stubs" name
  mkdir -p "$dir"
  for name in sudo pkexec; do
    cat >"$dir/$name" <<STUB
#!/bin/sh
echo "$name \$*" >>"$BATS_TEST_TMPDIR/launch.log"
[ "\$1" = "-n" ] && exit \${STUB_SUDO_N:-0}
exit \${STUB_STATUS:-0}
STUB
    chmod +x "$dir/$name"
  done
  export PATH="$dir:$PATH"
}

# ---- the helper itself ----

@test "helper refuses to run as a normal user" {
  run "$REPO_ROOT/libexec/devctl-root" version
  [ "$status" -eq 77 ]
  [[ $output == *"must run as root"* ]]
}

# The helper is standalone: load it in a clean shell, not next to devctl's core.
# logger is replaced so tests never write to the real system journal.
helper_fn() { bash -c 'source "$1"; logger() { :; }; shift; "$@"' _ "$REPO_ROOT/libexec/devctl-root" "$@"; }

@test "helper: caller must be a real non-root user from sudo or pkexec" {
  [ "$(SUDO_UID=1000 helper_fn caller_uid)" = 1000 ]
  [ "$(PKEXEC_UID=1001 helper_fn caller_uid)" = 1001 ]
  ! SUDO_UID=0 helper_fn caller_uid
  ! SUDO_UID='1000; rm' helper_fn caller_uid
  ! helper_fn caller_uid
}

@test "helper refuses to run from the repo (user-writable copy)" {
  ! helper_fn check_own_file
}

@test "helper contains no eval and sources nothing" {
  ! grep -nE '(^|[^_a-z])(eval|source)[[:space:]]|^[[:space:]]*\.[[:space:]]' "$REPO_ROOT/libexec/devctl-root"
}

@test "polkit policy is valid XML and points at the installed helper" {
  python3 -I -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "$REPO_ROOT/share/polkit/local.devctl.root.policy"
  grep -q '<annotate key="org.freedesktop.policykit.exec.path">/usr/local/libexec/devctl-root</annotate>' \
    "$REPO_ROOT/share/polkit/local.devctl.root.policy"
  grep -q '<allow_active>auth_admin_keep</allow_active>' "$REPO_ROOT/share/polkit/local.devctl.root.policy"
}

# ---- devctl's side ----

@test "helper state: missing, insecure (not root-owned), outdated" {
  DEVCTL_ROOT_HELPER="$BATS_TEST_TMPDIR/nope"
  [ "$(priv_helper_state)" = missing ]
  DEVCTL_ROOT_HELPER="$BATS_TEST_TMPDIR/mine"
  cp "$REPO_ROOT/libexec/devctl-root" "$DEVCTL_ROOT_HELPER"
  [ "$(priv_helper_state)" = insecure ]
  DEVCTL_ROOT_HELPER=/usr/bin/true   # root-owned, but not our helper
  [ "$(priv_helper_state)" = outdated ]
}

@test "priv_run refuses when the helper is missing or insecure" {
  DEVCTL_ROOT_HELPER="$BATS_TEST_TMPDIR/nope"
  run priv_run version
  [ "$status" -eq 7 ]
  [[ $output == *"devctl root install"* ]]
  DEVCTL_ROOT_HELPER="$BATS_TEST_TMPDIR/mine"
  touch "$DEVCTL_ROOT_HELPER"
  run priv_run version
  [ "$status" -eq 8 ]
}

@test "priv_run uses sudo from the terminal and pkexec from the dashboard" {
  fake_launchers
  priv_helper_state() { echo ok; }
  priv_run self-test
  DEVCTL_SOURCE=dashboard priv_run version
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/launch.log")" = "sudo -- /usr/local/libexec/devctl-root self-test" ]
  [ "$(sed -n 3p "$BATS_TEST_TMPDIR/launch.log")" = "pkexec /usr/local/libexec/devctl-root version" ]
}

@test "priv_run: dry-run shows the command and runs nothing" {
  fake_launchers
  priv_helper_state() { echo ok; }
  DEVCTL_DRY_RUN=1
  run priv_run --desc "Edit hosts" hosts-apply shop
  [[ $output == *"[dry-run] Edit hosts: sudo -- /usr/local/libexec/devctl-root hosts-apply shop"* ]]
  ! grep -q devctl-root "$BATS_TEST_TMPDIR/launch.log" 2>/dev/null
}

@test "priv_run maps refusal and cancelled authentication to EX_PRIVILEGE" {
  fake_launchers
  priv_helper_state() { echo ok; }
  STUB_STATUS=77 run priv_run version
  [ "$status" -eq 8 ]
  [[ $output == *"refused"* ]]
  STUB_STATUS=126 run priv_run version
  [ "$status" -eq 8 ]
  [[ $output == *"cancelled"* ]]
  STUB_STATUS=3 run priv_run version
  [ "$status" -eq 3 ]
}

@test "priv_run without a terminal and without cached sudo fails clearly" {
  fake_launchers
  priv_helper_state() { echo ok; }
  STUB_SUDO_N=1 run priv_run version </dev/null
  [ "$status" -eq 8 ]
  [[ $output == *"no terminal for the sudo password"* ]]
}

@test "devctl root: status json, dry-run install shows exact sudo commands" {
  run devctl --json root status
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.helper.path == "/usr/local/libexec/devctl-root"'
  if [ "$(echo "$output" | jq -r .helper.state)" != ok ]; then
    run devctl --dry-run root install
    [ "$status" -eq 0 ]
    [[ $output == *"sudo -- install -o root -g root -m 0755 -Z -T -- $REPO_ROOT/libexec/devctl-root /usr/local/libexec/devctl-root"* ]]
  fi
}

@test "devctl root install refuses without a terminal" {
  run devctl root install </dev/null
  [[ $status -eq 7 || $output == *"up to date"* ]]
}

@test "die inside \$(...) does not add an 'unexpected failure' line" {
  local repo
  repo=$(make_sandbox)
  cat >"$repo/lib/cmd/sub.sh" <<'CMD'
# summary: test command
inner() { die "$EX_NOTFOUND" "real reason"; }
cmd_sub() { local x; x=$(inner); echo "$x"; }
CMD
  run "$repo/bin/devctl" sub
  [ "$status" -eq 4 ]
  [[ $output == *"real reason"* && $output != *"unexpected failure"* ]]
}

@test "without a terminal on the desktop (e.g. the dashboard icon) pkexec is used" {
  fake_launchers
  priv_helper_state() { echo ok; }
  WAYLAND_DISPLAY=wayland-0 priv_run version </dev/null
  [ "$(tail -1 "$BATS_TEST_TMPDIR/launch.log")" = "pkexec /usr/local/libexec/devctl-root version" ]
}

@test "pkexec is never given \"--\" (it would try to run a program called --)" {
  fake_launchers
  priv_helper_state() { echo ok; }
  DEVCTL_SOURCE=dashboard priv_run project-label /x
  ! grep -q '^pkexec --' "$BATS_TEST_TMPDIR/launch.log"
  grep -q '^sudo -- ' <(priv_launcher() { echo sudo; }; DEVCTL_SOURCE=cli; priv_run version >/dev/null; cat "$BATS_TEST_TMPDIR/launch.log")
}
