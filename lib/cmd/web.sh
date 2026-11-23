# shellcheck shell=bash
# summary: Web server (Caddy): setup, HTTPS trust, start/stop, sites, apply, rollback

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action web.setup web.trust web.start web.stop web.apply web.rollback
adapter_load web

yes_no() { "$@" && echo yes || echo no; }

cmd_web() { cmd_web_status "$@"; }

cmd_web_status() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl web status"
  local sites
  sites=$(web_sites | wc -l)
  if ((DEVCTL_JSON)); then
    jq -nc --arg installed "$(yes_no web_installed)" --arg configured "$(yes_no web_configured)" \
      --arg confined "$(yes_no web_confined)" --arg running "$(yes_no web_running)" --argjson sites "$sites" \
      --arg system "$(web_trust_state system)" --arg brave "$(web_trust_state brave)" --arg firefox "$(web_trust_state firefox)" \
      '{installed: $installed, configured: $configured, selinux_confined: $confined, running: $running,
        sites: $sites, trust: {system: $system, brave: $brave, firefox: $firefox}}'
    return 0
  fi
  {
    printf 'server\t%s\n' "$(web_name)"
    printf 'installed\t%s\n' "$(yes_no web_installed)"
    printf 'configured by devctl\t%s\n' "$(yes_no web_configured)"
    printf 'SELinux-confined (httpd_t)\t%s\n' "$(yes_no web_confined)"
    printf 'running\t%s\n' "$(yes_no web_running)"
    printf 'sites\t%s\n' "$sites"
    printf 'HTTPS trusted: system / Brave / Firefox\t%s / %s / %s\n' \
      "$(web_trust_state system)" "$(web_trust_state brave)" "$(web_trust_state firefox)"
  } | ui_table
  if ! web_configured || ! web_confined; then
    ui_note "set up with: devctl web setup"
  fi
}

cmd_web_setup() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl web setup"
  local -a steps=()
  web_installed || steps+=("install the Fedora package caddy")
  web_confined || steps+=("SELinux: confine Caddy as httpd_t; allow proxying to local apps and reaching home folders; label ports 44300-44399 for Vite")
  web_configured || steps+=("write devctl's /etc/caddy/Caddyfile (original kept as Caddyfile.devctl-orig), admin API on a unix socket; let Caddy see only ~/Desktop/projects, read-only")
  if ((${#steps[@]} == 0)); then
    ui_skip "Caddy is installed, confined and configured"
    return 0
  fi
  ui_header "Web server setup (as administrator, via the helper)"
  printf '  - %s\n' "${steps[@]}"
  confirm_or_abort "Do this now?"
  web_installed || priv_run --desc "Install Caddy" pkg-install caddy
  web_confined || priv_run --desc "SELinux setup for Caddy" web-selinux-setup
  web_configured || priv_run --desc "Configure Caddy" caddy-setup
  ((DEVCTL_DRY_RUN)) && return 0
  web_apply
  ui_ok "Caddy is set up. Start it with: devctl web start; then trust its HTTPS: devctl web trust"
}

cmd_web_start() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl web start"
  web_configured || die "$EX_PRECONDITION" "set up first: devctl web setup"
  if web_running; then ui_skip "Caddy is already running"; return 0; fi
  web_start
  ((DEVCTL_DRY_RUN)) || ui_ok "Caddy is running"
}

cmd_web_stop() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl web stop"
  web_running || { ui_skip "Caddy is not running"; return 0; }
  web_stop
  ((DEVCTL_DRY_RUN)) || ui_ok "Caddy stopped"
}

cmd_web_sites() {
  local name
  local -a names=()
  mapfile -t names < <(web_sites)
  ((${#names[@]})) || { ui_skip "no sites"; return 0; }
  {
    printf 'SITE\tADDRESS\n'
    for name in "${names[@]}"; do
      printf '%s\t%s\n' "$name" "$(awk '/^[^#[:space:]].* \{$/ {print $1; exit}' "$(web_site_file "$name")")"
    done
  } | ui_table
}

cmd_web_apply() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl web apply"
  web_apply
  ((DEVCTL_DRY_RUN)) || ui_ok "Web server configuration applied"
}

cmd_web_rollback() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl web rollback"
  web_rollback
  ((DEVCTL_DRY_RUN)) || ui_ok "Previous web server configuration restored"
}

# trust: make browsers, the system (curl, PHP, Python, Java) and Node trust local HTTPS.
cmd_web_trust() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl web trust"
  web_configured || die "$EX_PRECONDITION" "set up first: devctl web setup"
  ui_header "Trust devctl's local HTTPS certificates"
  printf '%s\n' "  - system store (curl, PHP, Python, Java; Firefox on Fedora through p11-kit)" \
    "  - Brave (~/.pki/nssdb) and every Firefox profile" \
    "  - Node: devctl sets NODE_EXTRA_CA_CERTS for your projects" \
    "  The certificate authority's private key stays in /var/lib/caddy (root only)."
  confirm_or_abort "Trust it?"
  web_start
  if ((!DEVCTL_DRY_RUN)); then
    local pem i
    for ((i = 0; i < 20; i++)); do
      pem=$(priv_run --desc "Read the CA certificate" ca-export 2>/dev/null) && break
      sleep 0.5
    done
    [[ $pem == "-----BEGIN CERTIFICATE-----"* ]] || die "$EX_EXTERNAL" "could not read Caddy's CA certificate"
    local ca
    ca=$(web_ca_file)
    ensure_private_dir "${ca%/*}"
    printf '%s\n' "$pem" >"$ca"
    chmod 644 -- "$ca"
  fi
  priv_run --desc "Trust in the system store" ca-trust-system
  web_trust_user_dbs
  ((DEVCTL_DRY_RUN)) || ui_ok "Trusted. Restart Brave and Firefox so they pick it up."
}

complete_web() { return 0; }

help_web() {
  cat <<'HELP'
Usage: devctl web [status]     installed, confined, running, sites, HTTPS trust
       devctl web setup        install Caddy, confine it with SELinux, write its base config
       devctl web trust        trust its local HTTPS in the system, Brave, Firefox (and Node)
       devctl web start|stop   Caddy runs only when devctl needs it
       devctl web sites        sites the web server serves
       devctl web apply        re-apply the site configuration (validated, rolled back on error)
       devctl web rollback     go back to the previous working configuration

Caddy listens on 127.0.0.1/::1 only, runs as user "caddy", confined by SELinux (httpd_t),
with read-only access to your projects (ADR-0023). Logs: journalctl -u caddy
HELP
}
