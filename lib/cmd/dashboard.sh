# shellcheck shell=bash
# summary: Open the local web dashboard (start it if needed)

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

# The dashboard runs as a transient systemd user unit: started on demand, never at login,
# gone after logout or `devctl dashboard stop`. Login uses one-time codes (files, 0600)
# that the server deletes when used; the URL in browser history is worthless afterwards.

register_action dashboard.start dashboard.stop

readonly DASHBOARD_UNIT=devctl-dashboard.service
readonly DASHBOARD_MIN_PYTHON=311 # 3.11

dashboard__state_file() { printf '%s/dashboard.json\n' "$DEVCTL_RUN_DIR"; }
dashboard__login_dir() { printf '%s/dashboard-login\n' "$DEVCTL_RUN_DIR"; }
dashboard__port() { config_get dashboard.port; }

dashboard__running() {
  systemctl --user is-active --quiet "$DASHBOARD_UNIT"
}

# dashboard__ready PORT — the server wrote its state file for PORT (it does so after binding).
dashboard__ready() {
  local file
  file=$(dashboard__state_file)
  [[ -f $file ]] && jq -e --argjson port "$1" '.port == $port' "$file" >/dev/null 2>&1
}

dashboard__check_python() {
  local python version
  python=$(config_get dashboard.python)
  [[ -x $python ]] || die "$EX_PRECONDITION" "Python not found at $python (setting dashboard.python)"
  version=$("$python" -I -c 'import sys; print(sys.version_info[0] * 100 + sys.version_info[1])') ||
    die "$EX_EXTERNAL" "cannot run $python"
  ((version >= DASHBOARD_MIN_PYTHON)) || die "$EX_PRECONDITION" "the dashboard needs Python 3.11+ ($python is too old)"
}

cmd_dashboard() {
  cmd_dashboard_open "$@"
}

# open: start if needed, then open the browser with a fresh one-time login link.
cmd_dashboard_open() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl dashboard [open]"
  if ! dashboard__running; then
    router_mark_action dashboard.start
    dashboard__start
    ((DEVCTL_DRY_RUN)) && return 0
  fi
  dashboard__ensure_web
  local url
  url=$(dashboard__login_url)
  if ((DEVCTL_JSON)); then
    jq -nc --arg url "$url" '{running: true, login_url: $url}'
    return 0
  fi
  ui_step "Opening the dashboard in your browser"
  if ! xdg-open "$url" >/dev/null 2>&1; then
    ui_note "could not open a browser; open this link within 2 minutes:"
    printf '%s\n' "$url"
  fi
}

cmd_dashboard_start() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl dashboard start"
  dashboard__start
}

dashboard__start() {
  local port python i
  port=$(dashboard__port)
  python=$(config_get dashboard.python)

  if dashboard__running; then
    ui_skip "dashboard already running on http://127.0.0.1:$port"
    return 0
  fi
  dashboard__check_python
  if ss -ltnH "sport = :$port" | grep -q .; then
    die "$EX_CONFLICT" "port $port is already in use; choose another with dashboard.port in $DEVCTL_USER_CONFIG"
  fi

  ensure_private_dir "$DEVCTL_RUN_DIR"
  ensure_private_dir "$DEVCTL_STATE_DIR/dashboard"
  rm -f -- "$(dashboard__state_file)"
  # A failed earlier run leaves the transient unit in "failed" state, which blocks the name.
  systemctl --user reset-failed "$DASHBOARD_UNIT" 2>/dev/null || true

  run_change --desc "Start dashboard (transient user unit)" -- \
    systemd-run --user --quiet --collect --unit="$DASHBOARD_UNIT" \
    --description="devctl dashboard" \
    --setenv=DEVCTL_SOURCE=dashboard \
    -- "$python" -I "$DEVCTL_ROOT/dashboard/main.py" \
    --port "$port" \
    --domain "$(dashboard__domain)" \
    --devctl-bin "$DEVCTL_ROOT/bin/devctl" \
    --history-file "$DEVCTL_HISTORY_FILE" \
    --state-dir "$DEVCTL_STATE_DIR/dashboard" \
    --run-dir "$DEVCTL_RUN_DIR" ||
    die "$EX_EXTERNAL" "could not start the dashboard unit"
  ((DEVCTL_DRY_RUN)) && return 0

  for ((i = 0; i < 50; i++)); do
    dashboard__ready "$port" && break
    dashboard__running || break
    sleep 0.1
  done
  if ! dashboard__ready "$port"; then
    die "$EX_EXTERNAL" "dashboard did not start; see: journalctl --user -u $DASHBOARD_UNIT -n 20"
  fi
  ui_ok "Dashboard running on http://127.0.0.1:$port"
}

cmd_dashboard_stop() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl dashboard stop"
  if ! dashboard__running; then
    ui_skip "dashboard is not running"
    return 0
  fi
  run_change --desc "Stop dashboard" -- systemctl --user stop "$DASHBOARD_UNIT" ||
    die "$EX_EXTERNAL" "could not stop the dashboard"
  ui_ok "Dashboard stopped"
}

cmd_dashboard_status() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl dashboard status"
  local port running=false
  port=$(dashboard__port)
  dashboard__running && running=true
  if ((DEVCTL_JSON)); then
    jq -nc --argjson running "$running" --argjson port "$port" '{running: $running, port: $port}'
  elif [[ $running == true ]]; then
    printf 'running on http://127.0.0.1:%s\n' "$port"
  else
    printf 'not running\n'
  fi
}

# url: print a fresh one-time login link (for when the browser did not open).
cmd_dashboard_url() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl dashboard url"
  dashboard__running || die "$EX_PRECONDITION" "dashboard is not running; start it with: devctl dashboard"
  dashboard__login_url
}

dashboard__domain() { printf 'devctl.%s\n' "$(config_get domain.suffix)"; }

# dashboard__ensure_web — once Caddy is set up, serve the dashboard at https://devctl.<suffix>.
# Only asks for the administrator password when something actually changes.
dashboard__ensure_web() {
  adapter_load web
  web_configured || return 0
  adapter_load dns
  web_render proxy devctl "$(dashboard__domain)" on - "$(dashboard__port)" -
  dns_add "$(dashboard__domain)"
  dns_apply
  web_needs_apply && web_apply
  web_start
}

# dashboard__base_url — https://devctl.<suffix> when Caddy serves it, else the local port.
dashboard__base_url() {
  adapter_load web
  if web_configured && web_running && [[ -n $(web_sites | grep -x devctl || true) ]] &&
    getent ahosts "$(dashboard__domain)" >/dev/null 2>&1; then
    printf 'https://%s\n' "$(dashboard__domain)"
  else
    printf 'http://127.0.0.1:%s\n' "$(dashboard__port)"
  fi
}

# dashboard__login_url — create a one-time code (valid 2 minutes) and print the login URL.
dashboard__login_url() {
  local dir code
  dir=$(dashboard__login_dir)
  ensure_private_dir "$dir"
  # Forget codes that were never used.
  find "$dir" -maxdepth 1 -type f -mmin +2 -delete
  code=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
  (umask 077 && : >"$dir/$code")
  printf '%s/login?code=%s\n' "$(dashboard__base_url)" "$code"
}

help_dashboard() {
  cat <<'HELP'
Usage: devctl dashboard [open]   start the dashboard if needed and open it in your browser
       devctl dashboard start    start it without opening a browser
       devctl dashboard stop     stop it
       devctl dashboard status   running or not
       devctl dashboard url      print a fresh one-time login link

The dashboard runs on http://127.0.0.1:<dashboard.port> (default 7780), only reachable
from this laptop, as a temporary systemd user service (nothing starts at login).
Login links work once and expire after 2 minutes. The "devctl Dashboard" desktop icon
runs `devctl dashboard`.
Logs: journalctl --user -u devctl-dashboard
HELP
}
