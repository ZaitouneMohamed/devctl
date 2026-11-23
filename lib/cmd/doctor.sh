# shellcheck shell=bash
# summary: Check this machine for problems and offer a fix for each (asks first)

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

# Checks run in this order. Each doctor_check_<id> (dashes → underscores) only READS the
# system, through the probe_* functions below (tests replace those), and sets:
#   D_STATUS  ok | warn | fail | info      D_MESSAGE  one line for the user
#   D_FIX     what the fix does (empty = no automatic fix)
#   D_FIX_FN  function that applies it     D_FIX_ROOT 1 if the fix needs the privileged helper
readonly DOCTOR_CHECKS=(
  install helper selinux hostname docker-boot docker-pools web https-trust git-identity github watch subnets ports
  llmnr exposed certutil firewall disk encryption avahi legacy-dbs
)

declare -gA DOCTOR_TITLES=(
  [install]="devctl installed" [helper]="Privileged helper" [selinux]="SELinux"
  [hostname]="Hostname" [docker-boot]="Docker at boot" [docker-pools]="Docker address pools"
  [subnets]="Network overlaps" [ports]="Ports 80/443" [llmnr]="LLMNR"
  [exposed]="Open to the network" [certutil]="certutil (browser trust)" [firewall]="Firewall"
  [disk]="Disk space" [encryption]="Disk encryption" [avahi]="Avahi (.local names)"
  [legacy-dbs]="Old database containers" [web]="Web server (Caddy)" [https-trust]="Local HTTPS trusted"
  [git-identity]="Git name and email" [github]="GitHub sign-in" [watch]="Background checks"
)

D_STATUS="" D_MESSAGE="" D_FIX="" D_FIX_FN="" D_FIX_ROOT=0

d_result() { # d_result STATUS MESSAGE [FIX_DESCRIPTION FIX_FN [root]]
  D_STATUS=$1 D_MESSAGE=$2 D_FIX=${3:-} D_FIX_FN=${4:-} D_FIX_ROOT=0
  [[ ${5:-} == root ]] && D_FIX_ROOT=1
  return 0
}

# ---- probes (read-only; replaced in tests) ------------------------------------------------

probe_getenforce() { getenforce 2>/dev/null || printf 'unknown\n'; }
probe_static_hostname() { hostnamectl --static 2>/dev/null || true; }
probe_unit_enabled() { systemctl is-enabled "$1" 2>/dev/null || true; }
probe_unit_active() { systemctl is-active "$1" 2>/dev/null || true; }
probe_file_exists() { [[ -e $1 ]]; }
probe_file_contains() { grep -q -- "$2" "$1" 2>/dev/null; }
probe_llmnr_global() { resolvectl llmnr 2>/dev/null | sed -n 's/^Global: //p'; }
probe_listening() { ss -ltnH 2>/dev/null | awk '{print $4}'; }
probe_ipv4_networks() { ip -o -4 addr show 2>/dev/null | awk '{print $2, $4}'; }
probe_command() { command -v -- "$1" >/dev/null; }
probe_firewall_ports() { firewall-cmd --list-ports 2>/dev/null || true; }
probe_disk_used_percent() { df --output=pcent -- "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9'; }
probe_block_types() { lsblk -no TYPE 2>/dev/null | sort -u; }
probe_containers() { timeout 5 docker ps -a --format '{{.Names}}' 2>/dev/null || true; }

# ---- checks -----------------------------------------------------------------------------

doctor_check_install() {
  router__load_command self
  local kind name target source state expected bad=()
  make_temp_file expected
  self__render_desktop "$expected"
  while IFS=$'\t' read -r kind name target source; do
    state=$(self__state "$kind" "$target" "$source" "$expected")
    [[ $state == ok ]] || bad+=("$name:$state")
  done < <(self__items)
  if ((${#bad[@]} == 0)); then
    d_result ok "command, completion and launchers installed"
  else
    d_result warn "not up to date: ${bad[*]}" "run devctl self install" doctor_fix_install
  fi
}
doctor_fix_install() { cmd_self_install; }

doctor_check_helper() {
  local state
  state=$(priv_helper_state)
  case $state in
    ok) d_result ok "installed and up to date" ;;
    insecure) d_result fail "$DEVCTL_ROOT_HELPER is not root-owned or is writable by others" "reinstall it (devctl root install)" doctor_fix_helper ;;
    *) d_result warn "$state; needed for every fix below that changes the system" "install it (devctl root install, asks for your sudo password)" doctor_fix_helper ;;
  esac
}
doctor_fix_helper() {
  router__load_command root
  cmd_root_install
}

doctor_check_selinux() {
  local mode
  mode=$(probe_getenforce)
  if [[ $mode == Enforcing ]]; then
    d_result ok "enforcing"
  else
    # No automatic fix: devctl never changes the SELinux mode itself.
    d_result fail "$mode — devctl expects enforcing. Fix by hand: sudo setenforce 1, and SELINUX=enforcing in /etc/selinux/config"
  fi
}

doctor_check_hostname() {
  local want current
  want=$(config_get system.hostname)
  current=$(probe_static_hostname)
  if [[ $current == "$want" ]]; then
    d_result ok "$want (phones reach it as $want.local)"
  else
    d_result warn "static hostname is '${current:-not set}', expected '$want'" "set it to $want" doctor_fix_hostname root
  fi
}
doctor_fix_hostname() { priv_run --desc "Set static hostname" hostname-set "$(config_get system.hostname)"; }

doctor_check_docker_boot() {
  local service socket
  service=$(probe_unit_enabled docker.service)
  socket=$(probe_unit_enabled docker.socket)
  if [[ $service != enabled && $socket != enabled ]]; then
    d_result ok "not started at boot (devctl starts it when needed)"
  else
    d_result warn "starts at boot (docker.service: ${service:-?}, docker.socket: ${socket:-?})" \
      "disable at boot (a running Docker keeps running)" doctor_fix_docker_boot root
  fi
}
doctor_fix_docker_boot() { priv_run --desc "Disable Docker at boot" docker-boot-disable; }

doctor_check_docker_pools() {
  local file=/etc/docker/daemon.json
  if ! probe_file_exists "$file"; then
    d_result warn "not pinned: new Docker networks may later take 192.168.x.x ranges (VMware/LAN)" \
      "create $file with pools 172.20.0.0/14 (applies when Docker restarts)" doctor_fix_docker_pools root
  elif probe_file_contains "$file" default-address-pools; then
    d_result ok "pinned in $file"
  else
    d_result info "$file exists without default-address-pools; add them by hand if networks collide"
  fi
}
doctor_fix_docker_pools() { priv_run --desc "Pin Docker address pools" docker-address-pools; }

doctor_check_web() {
  adapter_load web
  if web_configured && web_confined; then
    d_result ok "installed, configured by devctl, confined by SELinux (httpd_t)"
  else
    d_result warn "not set up (needed for local sites and https://devctl.$(config_get domain.suffix))" \
      "set it up (devctl web setup: package, SELinux, base config)" doctor_fix_web root
  fi
}
doctor_fix_web() {
  router__load_command web
  cmd_web_setup
}

doctor_check_https_trust() {
  adapter_load web
  if ! web_configured; then
    d_result info "waiting for the web server (devctl web setup)"
    return 0
  fi
  local s b f
  s=$(web_trust_state system) b=$(web_trust_state brave) f=$(web_trust_state firefox)
  if [[ $s == yes && $b == yes && $f != no ]]; then
    d_result ok "system, Brave${f/#yes/, Firefox}"
  else
    d_result warn "system: $s, Brave: $b, Firefox: $f" "trust it (devctl web trust)" doctor_fix_https_trust root
  fi
}
doctor_fix_https_trust() {
  router__load_command web
  cmd_web_trust
}

# Your git identity is yours to choose: reported, never set by devctl.
doctor_check_git_identity() {
  local name email
  name=$(git config --global user.name || true)
  email=$(git config --global user.email || true)
  if [[ -n $name && -n $email ]]; then
    d_result ok "$name <$email>"
  else
    d_result warn "not set: commits will fail. Set it: git config --global user.name \"…\"; git config --global user.email \"…\""
  fi
}

doctor_check_github() {
  if ! command -v gh >/dev/null; then
    d_result warn "gh not installed: private repositories cannot be cloned" "install gh and sign in (devctl github setup)" doctor_fix_github root
  elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
    d_result warn "not signed in: private repositories cannot be cloned" "sign in (devctl github setup, opens your browser)" doctor_fix_github
  else
    d_result ok "signed in as $(gh api user --jq .login 2>/dev/null)"
  fi
}
doctor_fix_github() {
  router__load_command github
  cmd_github_setup
}

doctor_check_watch() {
  if [[ $(systemctl --user is-enabled devctl-watch.timer 2>/dev/null) == enabled ]]; then
    d_result ok "on (disk, crashed containers, image updates every 30 min)"
  else
    d_result warn "off: no alerts for a full disk, crashed containers or image updates" \
      "turn on the user timer (devctl watch enable)" doctor_fix_watch
  fi
}
doctor_fix_watch() {
  router__load_command watch
  cmd_watch_enable
}

# ip4_to_int A.B.C.D
ip4_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  printf '%s\n' "$(((a << 24) | (b << 16) | (c << 8) | d))"
}

# cidr_overlap A/n B/m — status 0 if the two IPv4 networks overlap.
cidr_overlap() {
  local a=${1%/*} an=${1#*/} b=${2%/*} bn=${2#*/} n mask
  n=$((an < bn ? an : bn))
  mask=$(((0xFFFFFFFF << (32 - n)) & 0xFFFFFFFF))
  local ia ib
  ia=$(ip4_to_int "$a")
  ib=$(ip4_to_int "$b")
  (((ia & mask) == (ib & mask)))
}

doctor_check_subnets() {
  local -a names=() nets=() clashes=()
  local name net i j
  while read -r name net; do
    [[ $name == lo || -z $net ]] && continue
    names+=("$name")
    nets+=("$net")
  done < <(probe_ipv4_networks)
  for ((i = 0; i < ${#nets[@]}; i++)); do
    for ((j = i + 1; j < ${#nets[@]}; j++)); do
      cidr_overlap "${nets[i]}" "${nets[j]}" && clashes+=("${names[i]} ${nets[i]} ↔ ${names[j]} ${nets[j]}")
    done
  done
  if ((${#clashes[@]} == 0)); then
    d_result ok "no overlaps between ${#nets[@]} networks (LAN, VMware, Docker)"
  else
    d_result fail "overlapping networks: ${clashes[*]}; traffic may go to the wrong place"
  fi
}

doctor_check_ports() {
  local port addr busy=()
  for port in 80 443; do
    while read -r addr; do
      [[ $addr == *:"$port" ]] && busy+=("$addr")
    done < <(probe_listening)
  done
  if ((${#busy[@]} == 0)); then
    d_result ok "free for Caddy"
  elif probe_unit_active caddy.service | grep -qx active; then
    d_result ok "used by Caddy (${busy[*]})"
  else
    d_result warn "in use by another program: ${busy[*]} — Caddy needs them. See which: sudo ss -ltnp"
  fi
}

doctor_check_llmnr() {
  local value
  value=$(probe_llmnr_global)
  if [[ $value == no ]]; then
    d_result ok "disabled"
  else
    d_result warn "enabled (${value:-unknown}): anyone on the network can answer name lookups (spoofing risk on public Wi-Fi)" \
      "disable LLMNR on all networks (systemd-resolved drop-in)" doctor_fix_llmnr root
  fi
}
doctor_fix_llmnr() { priv_run --desc "Disable LLMNR" llmnr-disable; }

# Listening on every interface = reachable from the network. Loopback-only is fine.
doctor_check_exposed() {
  local addr port exposed=()
  while read -r addr; do
    port=${addr##*:}
    case $addr in
      0.0.0.0:* | \[::\]:* | \*:*) ;;
      *) continue ;;
    esac
    [[ $port == 5355 ]] && continue # LLMNR: its own check
    exposed+=("$port")
  done < <(probe_listening)
  if ((${#exposed[@]} == 0)); then
    d_result ok "nothing listens on all interfaces"
  else
    mapfile -t exposed < <(printf '%s\n' "${exposed[@]}" | sort -un)
    d_result info "listening on all interfaces: port(s) ${exposed[*]} — see which programs: sudo ss -ltnp"
  fi
}

doctor_check_certutil() {
  if probe_command certutil; then
    d_result ok "installed"
  else
    d_result warn "missing: needed to make Brave and Firefox trust local HTTPS" \
      "install nss-tools (Fedora package; cancels updates GNOME Software scheduled for reboot — it schedules them again)" doctor_fix_certutil root
  fi
}
doctor_fix_certutil() { priv_run --desc "Install nss-tools" pkg-install nss-tools; }

doctor_check_firewall() {
  local ports
  ports=$(probe_firewall_ports)
  if [[ $ports == *1025-65535* ]]; then
    d_result info "default zone allows all ports 1025-65535 from the network (Fedora default); to revisit with sharing (ADR-0014)"
  else
    d_result ok "default zone does not open the high port range"
  fi
}

doctor_check_disk() {
  local used free limit
  used=$(probe_disk_used_percent)
  limit=$(config_get guard.disk_min_free_percent)
  if ! is_uint "$used"; then
    d_result info "could not read disk usage"
    return 0
  fi
  free=$((100 - used))
  if ((free <= limit)); then
    d_result warn "only ${free}% free on your home disk (warning at ${limit}%)"
  else
    d_result ok "${free}% free"
  fi
}

doctor_check_encryption() {
  if probe_block_types | grep -qx crypt; then
    d_result ok "encrypted (LUKS)"
  else
    d_result info "not encrypted — your choice for now; secrets and database files are readable if the laptop is stolen"
  fi
}

doctor_check_avahi() {
  if [[ $(probe_unit_active avahi-daemon.service) == active ]]; then
    d_result ok "active (needed for $(config_get system.hostname).local)"
  else
    d_result info "not running: $(config_get system.hostname).local will not resolve for phones (only needed for sharing)"
  fi
}

doctor_check_legacy_dbs() {
  local found=()
  [[ $(probe_unit_active docker.service) == active ]] || {
    d_result ok "Docker not running; nothing to check"
    return 0
  }
  mapfile -t found < <(probe_containers | grep -xE 'dev-mysql|dev-postgres' || true)
  if ((${#found[@]} == 0)); then
    d_result ok "none"
  else
    d_result info "${found[*]} from ~/Desktop/projects/databases: removed once devctl's database module works (ADR-0016)"
  fi
}

# ---- running ----------------------------------------------------------------------------

doctor__run_check() { # doctor__run_check ID — sets D_* (a failing check becomes "info")
  d_result info "check could not run"
  "doctor_check_${1//-/_}" || d_result info "check could not run (see devctl --verbose doctor)"
}

# Public interface for other commands (init): run one check and ask about the result.
doctor_status_of() {
  doctor__run_check "$1"
  printf '%s\n' "$D_STATUS"
}
doctor_fixable() {
  doctor__run_check "$1"
  [[ -n $D_FIX_FN ]]
}
doctor_title() { printf '%s\n' "${DOCTOR_TITLES[$1]}"; }

doctor__symbol() {
  case $1 in
    ok) ui_paint 1 green '✓' ;;
    warn) ui_paint 1 yellow '!' ;;
    fail) ui_paint 1 red '✗' ;;
    *) ui_paint 1 blue 'i' ;;
  esac
}

cmd_doctor() {
  local fix=1 id problems=0 json_rows=()
  local -a fixable=()
  while (($#)); do
    case $1 in
      --check) fix=0 ;;
      *) die "$EX_USAGE" "usage: devctl doctor [--check]" ;;
    esac
    shift
  done
  ((DEVCTL_JSON)) && fix=0

  for id in "${DOCTOR_CHECKS[@]}"; do
    doctor__run_check "$id"
    [[ $D_STATUS == warn || $D_STATUS == fail ]] && ((++problems))
    [[ -n $D_FIX_FN ]] && fixable+=("$id")
    if ((DEVCTL_JSON)); then
      json_rows+=("$id" "${DOCTOR_TITLES[$id]}" "$D_STATUS" "$D_MESSAGE" "$D_FIX")
    else
      printf '%s %-26s %s\n' "$(doctor__symbol "$D_STATUS")" "${DOCTOR_TITLES[$id]}" "$D_MESSAGE"
    fi
  done

  if ((DEVCTL_JSON)); then
    jq -n --argjson r "$(json_array "${json_rows[@]}")" \
      '[range(0; $r | length; 5) as $i
        | {id: $r[$i], title: $r[$i + 1], status: $r[$i + 2], message: $r[$i + 3], fix: $r[$i + 4]}]'
  elif ((problems == 0)); then
    ui_ok "No problems found"
  elif ((fix && ${#fixable[@]})); then
    doctor__offer_fixes "${fixable[@]}" || problems=$?
  else
    ui_note "$problems problem(s). Run 'devctl doctor' in a terminal to fix them one by one."
  fi
  ((problems == 0)) || exit "$EX_FAIL"
}

# doctor__offer_fixes ID... — ask before each fix; returns the number of problems left.
doctor__offer_fixes() {
  local id left=0
  printf '\n'
  for id in "$@"; do
    doctor__run_check "$id" # state may have changed (e.g. helper just installed)
    [[ -n $D_FIX_FN ]] || continue
    if ((D_FIX_ROOT)) && [[ $(priv_helper_state) != ok ]]; then
      ui_skip "${DOCTOR_TITLES[$id]}: needs the privileged helper first (devctl root install)"
      ((++left))
      continue
    fi
    if ! confirm "Fix '${DOCTOR_TITLES[$id]}': $D_FIX?"; then
      ui_skip "${DOCTOR_TITLES[$id]}: left as is"
      ((++left))
      continue
    fi
    router_mark_action doctor.fix
    if "$D_FIX_FN"; then
      ((DEVCTL_DRY_RUN)) && continue
      doctor__run_check "$id"
      if [[ $D_STATUS == ok ]]; then
        ui_ok "${DOCTOR_TITLES[$id]}: $D_MESSAGE"
      else
        ui_note "${DOCTOR_TITLES[$id]}: $D_MESSAGE"
        ((++left))
      fi
    else
      ui_fail "${DOCTOR_TITLES[$id]}: fix failed"
      ((++left))
    fi
  done
  return "$left"
}

complete_doctor() {
  [[ $1 == flags ]] && printf '%s\n' --check
  return 0
}

help_doctor() {
  cat <<'HELP'
Usage: devctl doctor            check, then offer a fix for each problem (asks each time)
       devctl doctor --check    check only, change nothing
       devctl --json doctor     machine-readable results (check only)
       devctl --dry-run doctor  show the exact commands the fixes would run

Symbols: ✓ ok · ! warning · ✗ problem · i information (no action needed)
Fixes that change the system go through the privileged helper (sudo password).
Checks: devctl install, privileged helper, SELinux, hostname, Docker at boot, Docker
address pools, network overlaps (LAN/VMware/Docker), ports 80/443, LLMNR, programs open
to the network, certutil, firewall, disk space, disk encryption, Avahi, old DB containers.
Exit code: 0 no problems · 1 problems remain.
HELP
}
