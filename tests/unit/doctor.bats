#!/usr/bin/env bats
load '../helpers/common'

setup() {
  setup_home
  load_core
  router__load_command doctor
  # A healthy machine; each test breaks one thing.
  probe_getenforce() { echo Enforcing; }
  probe_static_hostname() { echo zaitoune-laptop; }
  probe_unit_enabled() { echo disabled; }
  probe_unit_active() { case $1 in avahi-daemon.service) echo active ;; *) echo inactive ;; esac; }
  probe_file_exists() { return 0; }
  probe_file_contains() { return 0; }
  probe_llmnr_global() { echo no; }
  probe_listening() { printf '%s\n' 127.0.0.1:631 '[::1]:631'; }
  probe_ipv4_networks() { printf '%s\n' 'lo 127.0.0.1/8' 'wlp0s20f3 192.168.11.121/24' 'vmnet1 192.168.227.1/24' 'docker0 172.17.0.1/16'; }
  probe_command() { return 0; }
  probe_firewall_ports() { echo ""; }
  probe_disk_used_percent() { echo 29; }
  probe_block_types() { printf '%s\n' disk part crypt; }
  probe_containers() { :; }
}

check() { doctor__run_check "$1"; echo "$D_STATUS|$D_MESSAGE|$D_FIX_FN|$D_FIX_ROOT"; }

@test "healthy values pass" {
  for id in selinux hostname docker-boot docker-pools subnets ports llmnr exposed certutil firewall disk encryption avahi legacy-dbs; do
    run check "$id"
    [[ $output == ok\|* ]] || { echo "$id: $output"; return 1; }
  done
}

@test "selinux not enforcing: fail, and never an automatic fix" {
  probe_getenforce() { echo Permissive; }
  run check selinux
  [[ $output == fail\|*"setenforce 1"*\|\|0 ]]
}

@test "hostname mismatch offers a root fix with the configured name" {
  probe_static_hostname() { echo ""; }
  run check hostname
  [[ $output == "warn|static hostname is 'not set', expected 'zaitoune-laptop'|doctor_fix_hostname|1" ]]
}

@test "docker enabled at boot (service or socket)" {
  probe_unit_enabled() { [[ $1 == docker.socket ]] && echo enabled || echo disabled; }
  run check docker-boot
  [[ $output == warn\|*doctor_fix_docker_boot\|1 ]]
}

@test "docker pools: missing file is fixable; foreign file is only info" {
  probe_file_exists() { return 1; }
  run check docker-pools
  [[ $output == warn\|*doctor_fix_docker_pools\|1 ]]
  probe_file_exists() { return 0; }
  probe_file_contains() { return 1; }
  run check docker-pools
  [[ $output == info\|*\|\|0 ]]
}

@test "subnet overlap detection" {
  cidr_overlap 192.168.11.0/24 192.168.11.128/25
  cidr_overlap 172.16.0.0/12 172.20.5.0/24
  ! cidr_overlap 192.168.11.0/24 192.168.227.0/24
  ! cidr_overlap 172.17.0.1/16 172.18.0.1/16
  probe_ipv4_networks() { printf '%s\n' 'wlp0s20f3 192.168.108.40/24' 'vmnet8 192.168.108.1/24'; }
  run check subnets
  [[ $output == fail\|*"wlp0s20f3 192.168.108.40/24 ↔ vmnet8 192.168.108.1/24"* ]]
}

@test "ports 80/443 busy by something that is not Caddy" {
  probe_listening() { printf '%s\n' 0.0.0.0:80 127.0.0.1:3306; }
  run check ports
  [[ $output == warn\|*0.0.0.0:80* ]]
  probe_unit_active() { echo active; }
  run check ports
  [[ $output == ok\|"used by Caddy"* ]]
}

@test "LLMNR enabled offers the fix" {
  probe_llmnr_global() { echo resolve; }
  run check llmnr
  [[ $output == warn\|*doctor_fix_llmnr\|1 ]]
}

@test "exposed listeners are listed once, LLMNR excluded, loopback ignored" {
  probe_listening() { printf '%s\n' 0.0.0.0:27500 '[::]:27500' 0.0.0.0:5355 127.0.0.1:3306 '*:8080'; }
  run check exposed
  [[ $output == "info|listening on all interfaces: port(s) 8080 27500"* ]]
}

@test "certutil missing offers nss-tools" {
  probe_command() { [[ $1 != certutil ]]; }
  run check certutil
  [[ $output == warn\|*doctor_fix_certutil\|1 ]]
}

@test "disk: warning at the configured limit" {
  probe_disk_used_percent() { echo 80; }
  run check disk
  [[ $output == warn\|"only 20% free"* ]]
  probe_disk_used_percent() { echo ""; }
  run check disk
  [[ $output == info\|* ]]
}

@test "information-only checks" {
  probe_firewall_ports() { echo "1025-65535/tcp 1025-65535/udp"; }
  run check firewall
  [[ $output == info\|* ]]
  probe_block_types() { printf '%s\n' disk part; }
  run check encryption
  [[ $output == info\|"not encrypted"* ]]
  probe_unit_active() { echo active; }
  probe_containers() { printf '%s\n' dev-mysql other dev-postgres; }
  run check legacy-dbs
  [[ $output == "info|dev-mysql dev-postgres from"* ]]
}

@test "a crashing check becomes info instead of aborting doctor" {
  doctor_check_disk() { return 3; }
  run check disk
  [[ $output == info\|"check could not run"* ]]
}

@test "fixes needing the helper are skipped while it is missing" {
  DEVCTL_ROOT_HELPER="$BATS_TEST_TMPDIR/nope"
  probe_llmnr_global() { echo yes; }
  DEVCTL_ASSUME_YES=1
  run doctor__offer_fixes llmnr
  [ "$status" -eq 1 ]
  [[ $output == *"needs the privileged helper first"* ]]
}

@test "declined fix is left as is" {
  probe_llmnr_global() { echo yes; }
  priv_helper_state() { echo ok; }
  confirm() { return 1; }
  run doctor__offer_fixes llmnr
  [ "$status" -eq 1 ]
  [[ $output == *"LLMNR: left as is"* ]]
}

@test "accepted fix runs and is re-checked" {
  probe_llmnr_global() { echo yes; }
  priv_helper_state() { echo ok; }
  confirm() { return 0; }
  doctor_fix_llmnr() { probe_llmnr_global() { echo no; }; }
  run doctor__offer_fixes llmnr
  [ "$status" -eq 0 ]
  [[ $output == *"✓ LLMNR: disabled"* ]]
}

@test "devctl doctor --json and --check on the real machine" {
  run devctl --json doctor
  echo "$output" | jq -e 'length == 21 and all(.[]; .status | IN("ok","warn","fail","info"))'
  run devctl doctor --check
  [[ $status -eq 0 || $status -eq 1 ]]
  [[ $output != *"Fix '"* ]]
}

# ---- helper verbs used by the fixes (validation only; acting needs root) ----

# logger is replaced so tests never write to the real system journal.
helper_fn() { bash -c 'source "$1"; logger() { :; }; shift; "$@"' _ "$REPO_ROOT/libexec/devctl-root" "$@"; }

@test "helper: hostname validation" {
  helper_fn valid_hostname zaitoune-laptop
  ! helper_fn valid_hostname Zaitoune
  ! helper_fn valid_hostname 'a;b'
  ! helper_fn valid_hostname -lead
  run helper_fn verb_hostname_set 'bad name'
  [ "$status" -eq 64 ]
}

@test "helper: packages only from the allow-list" {
  run helper_fn verb_pkg_install curl
  [ "$status" -eq 64 ]
  [[ $output == *"not on devctl's allow-list"* ]]
  run helper_fn verb_pkg_install nss-tools '--repofrompath=x'
  [ "$status" -eq 64 ]
  run helper_fn verb_pkg_install
  [ "$status" -eq 64 ]
}

@test "helper: verbs without arguments reject extra arguments" {
  for verb in verb_docker_boot_disable verb_docker_address_pools verb_llmnr_disable verb_listeners; do
    run helper_fn "$verb" extra
    [ "$status" -eq 64 ] || { echo "$verb accepted an argument"; return 1; }
  done
}
