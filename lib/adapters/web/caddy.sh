# shellcheck shell=bash
# Web server adapter: Caddy (ADR-0003, ADR-0023). The only file that knows Caddy.
#
# Desired state = one file per site in the staging folder (written as you); the helper's
# caddy-apply mirrors it into /etc/caddy/devctl, validates, reloads, and rolls back on error.

# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

WEB_STAGING_DIR="$DEVCTL_DATA_DIR/caddy/sites"
WEB_TEMPLATES_DIR="$DEVCTL_ROOT/templates/caddy"
WEB_CA_FILE="$DEVCTL_DATA_DIR/ca/root.crt"
readonly WEB_CA_NAME="devctl local CA"

web_name() { printf 'caddy\n'; }
web_site_file() { printf '%s/%s.caddy\n' "$WEB_STAGING_DIR" "$1"; }
web_ca_file() { printf '%s\n' "$WEB_CA_FILE"; }
web_installed() { [[ -x /usr/bin/caddy ]]; }
# Configured = devctl's Caddyfile and the current sandbox drop-in (projects folder visible).
web_configured() {
  grep -qs 'Managed by devctl' /etc/caddy/Caddyfile &&
    grep -qs '^BindReadOnlyPaths=' /etc/systemd/system/caddy.service.d/devctl.conf
}
web_running() { systemctl is-active --quiet caddy.service; }

# web_confined — Caddy's binary carries the label that makes SELinux confine it (httpd_t).
web_confined() { [[ $(stat -c %C /usr/bin/caddy 2>/dev/null) == *:httpd_exec_t:* ]]; }

# The helper reads staging from ~/.local/share/devctl (it never trusts environment
# variables), so a custom XDG_DATA_HOME cannot be used for web sites.
web__check_staging_path() {
  [[ $WEB_STAGING_DIR == "$HOME/.local/share/devctl/caddy/sites" ]] ||
    die "$EX_PRECONDITION" "web sites need the default data folder (~/.local/share); unset XDG_DATA_HOME"
}

web_sites() {
  local f
  for f in "$WEB_STAGING_DIR"/*.caddy; do
    [[ -f $f ]] || continue
    f=${f##*/}
    printf '%s\n' "${f%.caddy}"
  done
}

# web_render KIND NAME DOMAIN TLS ROOT UPSTREAM FPM_SOCKET [VITE_PORT] — write the site file.
#   KIND php|static|proxy; TLS on|off; unused values as "-". VITE_PORT adds the HTTPS
#   listener for the site's Vite dev server (public port; Vite listens on port + 10000).
web_render() {
  local kind=$1 name=$2 domain=$3 tls=$4 root=$5 upstream=$6 fpm=$7 vite=${8:--} tmpl content address
  is_in_list "$kind" php static proxy stopped || die "$EX_FAIL" "unknown site kind '$kind' (bug)"
  [[ $name =~ ^[a-z][a-z0-9-]{0,62}$ ]] || die "$EX_FAIL" "bad site name '$name' (bug)"
  [[ $domain =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "$EX_FAIL" "bad domain '$domain' (bug)"
  [[ $root == - || ($root == /* && $root =~ ^[A-Za-z0-9/._+-]+$) ]] ||
    die "$EX_VALIDATION" "the path '$root' has characters the web server config cannot use"
  [[ $upstream == - ]] || is_port "$upstream" || die "$EX_FAIL" "bad upstream port (bug)"
  [[ $fpm == - || $fpm =~ ^/run/[A-Za-z0-9/._-]+\.sock$ || $fpm =~ ^/var/opt/remi/php8[0-9]/run/php-fpm/devctl\.sock$ ]] ||
    die "$EX_FAIL" "bad FPM socket (bug)"
  web__check_staging_path
  address=$domain
  [[ $tls == off ]] && address="http://$domain"
  tmpl="$WEB_TEMPLATES_DIR/$kind.caddy.tmpl"
  content=$(<"$tmpl")
  content=${content//\{\{NAME\}\}/$name}
  content=${content//\{\{ADDRESS\}\}/$address}
  content=${content//\{\{ROOT\}\}/$root}
  content=${content//\{\{UPSTREAM\}\}/$upstream}
  content=${content//\{\{FPM_SOCKET\}\}/$fpm}
  if [[ $vite != - ]]; then
    if ! is_port "$vite" || ! is_port $((vite + 10000)); then die "$EX_FAIL" "bad Vite port (bug)"; fi
    local frag
    frag=$(<"$WEB_TEMPLATES_DIR/vite.caddy.tmpl")
    frag=${frag//\{\{NAME\}\}/$name}
    frag=${frag//\{\{DOMAIN\}\}/$domain}
    frag=${frag//\{\{VITE_PUBLIC\}\}/$vite}
    frag=${frag//\{\{VITE_INTERNAL\}\}/$((vite + 10000))}
    content+=$'\n'$frag
  fi
  [[ $content != *'{{'* ]] || die "$EX_FAIL" "unfilled placeholder in $tmpl (bug)"
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "write web config for $name ($kind, ${address})"
    return 0
  fi
  ensure_private_dir "$WEB_STAGING_DIR"
  printf '%s\n' "$content" >"$WEB_STAGING_DIR/$name.caddy"
}

web_remove() {
  [[ -e $WEB_STAGING_DIR/$1.caddy ]] || return 0
  run_change --desc "Remove web config for $1" -- rm -f -- "$WEB_STAGING_DIR/$1.caddy"
}

web_apply() {
  web__check_staging_path
  ensure_private_dir "$WEB_STAGING_DIR"
  priv_run --desc "Apply web server configuration (validated; rolled back on error)" caddy-apply
}

# web_needs_apply — the staged sites differ from what Caddy serves.
web_needs_apply() {
  local live=/etc/caddy/devctl name
  [[ -d $live ]] || return 0
  for name in "$WEB_STAGING_DIR"/*.caddy; do
    [[ -f $name ]] || continue
    cmp -s -- "$name" "$live/${name##*/}" || return 0
  done
  for name in "$live"/*.caddy; do
    [[ ${name##*/} == 00-devctl.caddy || -f $WEB_STAGING_DIR/${name##*/} ]] || return 0
  done
  return 1
}

web_rollback() { priv_run --desc "Restore the previous web server configuration" caddy-rollback; }
web_start() { web_running || priv_run --desc "Start Caddy" caddy-start; }
web_stop() { web_running && priv_run --desc "Stop Caddy" caddy-stop; return 0; }

# ---- trust of the local CA ------------------------------------------------------------------

web__nssdb_has() { certutil -L -d "sql:$1" -n "$WEB_CA_NAME" >/dev/null 2>&1; }

web_trust_firefox_dbs() {
  local dir
  for dir in "$HOME"/.mozilla/firefox/*/ "$HOME"/.config/mozilla/firefox/*/; do
    [[ -f $dir/cert9.db ]] && printf '%s\n' "${dir%/}"
  done
  return 0
}

# web_trust_state TARGET — yes | no | n/a   (TARGET: system | brave | firefox)
web_trust_state() {
  case $1 in
    system) [[ -f /etc/pki/ca-trust/source/anchors/devctl-caddy-local.crt ]] && echo yes || echo no ;;
    brave)
      command -v certutil >/dev/null || { echo no; return; }
      web__nssdb_has "$HOME/.pki/nssdb" && echo yes || echo no
      ;;
    firefox)
      local db any=0
      command -v certutil >/dev/null || { echo no; return; }
      while IFS= read -r db; do
        any=1
        web__nssdb_has "$db" || { echo no; return; }
      done < <(web_trust_firefox_dbs)
      ((any)) && echo yes || echo n/a
      ;;
  esac
}

web_trust_user_dbs() { # import the CA into Brave's and Firefox's NSS databases (as you)
  local db
  command -v certutil >/dev/null || die "$EX_PRECONDITION" "certutil is missing (devctl doctor installs nss-tools)"
  if [[ ! -f $HOME/.pki/nssdb/cert9.db ]]; then
    run_change --desc "Create Brave's certificate store" -- mkdir -p -- "$HOME/.pki/nssdb"
    run_change --desc "Create Brave's certificate store" -- certutil -N -d "sql:$HOME/.pki/nssdb" --empty-password
  fi
  { web_trust_firefox_dbs; printf '%s\n' "$HOME/.pki/nssdb"; } | while IFS= read -r db; do
    web__nssdb_has "$db" && continue
    run_change --desc "Trust in $db" -- certutil -A -d "sql:$db" -n "$WEB_CA_NAME" -t "C,," -i "$WEB_CA_FILE"
  done
}
