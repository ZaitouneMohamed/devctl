# shellcheck shell=bash
# summary: Background checks every 30 min: low disk, crashed containers, image updates

# shellcheck source=lib/services/dbservers.sh
source "${DEVCTL_ROOT:?}/lib/services/dbservers.sh"

register_action watch.enable watch.disable

# ADR-0010: a systemd *user* timer (enabled once, after asking) runs `devctl watch tick`.
# Each check only reads and notifies; Docker checks run only when Docker is already active.
# Each alert is sent once (state files below), so a full disk does not notify every 30 min.

readonly WATCH_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
readonly WATCH_TIMER=devctl-watch.timer
readonly WATCH_DISK_REPEAT_SECONDS=$((6 * 3600))
readonly WATCH_IMAGES_EVERY_SECONDS=$((24 * 3600))
WATCH_STATE_DIR="$DEVCTL_STATE_DIR/watch"

watch__now() { printf '%(%s)T\n' -1; }

# watch__seen KEY — status 0 if KEY was already reported; watch__remember KEY records it.
watch__seen() { grep -qxF -- "$1" "$WATCH_STATE_DIR/seen" 2>/dev/null; }
watch__remember() {
  ensure_private_dir "$WATCH_STATE_DIR"
  printf '%s\n' "$1" >>"$WATCH_STATE_DIR/seen"
  # keep the file small
  if (($(wc -l <"$WATCH_STATE_DIR/seen") > 500)); then
    tail -n 300 -- "$WATCH_STATE_DIR/seen" >"$WATCH_STATE_DIR/seen.tmp" && mv -f -- "$WATCH_STATE_DIR/seen.tmp" "$WATCH_STATE_DIR/seen"
  fi
}

# watch__due NAME SECONDS — status 0 if NAME last ran more than SECONDS ago (then records now).
watch__due() {
  local file="$WATCH_STATE_DIR/$1.last" last=0
  [[ -f $file ]] && last=$(<"$file")
  is_uint "$last" || last=0
  (($(watch__now) - last >= $2)) || return 1
  ensure_private_dir "$WATCH_STATE_DIR"
  watch__now >"$file"
}

# ---- checks (each prints one line: ok | alert: … | skipped: …) ----------------------------

watch_check_disk() {
  local used free limit
  used=$(df --output=pcent -- "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
  is_uint "$used" || { echo "skipped: cannot read disk usage"; return 0; }
  free=$((100 - used))
  limit=$(config_get guard.disk_min_free_percent)
  if ((free > limit)); then
    rm -f -- "$WATCH_STATE_DIR/disk.last"
    echo "ok: ${free}% free"
    return 0
  fi
  if watch__due disk "$WATCH_DISK_REPEAT_SECONDS" || [[ ${WATCH_FORCE:-0} == 1 ]]; then
    notify critical "Disk almost full" "Only ${free}% free on your home disk (warning at ${limit}%)."
    history_record_alert warn disk-low "only ${free}% free on the home disk (warning at ${limit}%)"
  fi
  echo "alert: only ${free}% free"
}

watch_check_crashes() {
  ce_daemon_running || { echo "skipped: Docker not running"; return 0; }
  local name code restarts finished n=0
  while IFS=$'\t' read -r name code restarts finished; do
    [[ -n $name ]] || continue
    ((++n))
    watch__seen "crash:$name:$finished" && continue
    watch__remember "crash:$name:$finished"
    notify critical "Container stopped: $name" "It exited with code $code after $restarts restart(s). Logs: devctl logs or docker logs $name"
    history_record_alert error container-crashed "$name exited with code $code after $restarts restart(s)"
  done < <(ce_crashed)
  ((n == 0)) && echo "ok: no crashed containers" || echo "alert: $n crashed container(s)"
}

watch_check_images() {
  ce_daemon_running || { echo "skipped: Docker not running"; return 0; }
  if ! watch__due images "$WATCH_IMAGES_EVERY_SECONDS" && [[ ${WATCH_FORCE:-0} != 1 ]]; then
    echo "skipped: checked in the last 24 h"
    return 0
  fi
  local id engine major image port created have remote
  local -a newer=()
  [[ -f $DB_SERVERS_FILE ]] || { echo "ok: no servers"; return 0; }
  while IFS=$'\t' read -r id engine major image port created; do
    [[ -n $image ]] || continue
    have=$(ce_image_local_digest "$image") || have=""
    [[ -n $have ]] || continue # not downloaded yet
    remote=$(ce_image_remote_digest "$image") || remote="" # offline: try again next time
    [[ -n $remote && $remote != "$have" ]] || continue
    newer+=("$image")
    watch__seen "image:$image:$remote" && continue
    watch__remember "image:$image:$remote"
    notify normal "Newer image: $image" "A newer $image is available. devctl never updates by itself; to update: docker pull $image, then restart the server."
    history_record_alert info image-update "newer $image available (devctl never updates by itself)"
  done <"$DB_SERVERS_FILE"
  ((${#newer[@]} == 0)) && echo "ok: images up to date" || echo "alert: newer image(s): ${newer[*]}"
}

watch_housekeeping() {
  log_prune "$(config_get log.retention_days)" && echo "ok: logs older than $(config_get log.retention_days) days removed"
}

# ---- commands ---------------------------------------------------------------------------

# tick: what the timer runs. Also usable by hand (`devctl watch tick --force` re-sends alerts).
cmd_watch_tick() {
  case ${1:-} in
    "") ;;
    --force) WATCH_FORCE=1 ;;
    *) die "$EX_USAGE" "usage: devctl watch tick [--force]" ;;
  esac
  local check
  for check in disk crashes images; do
    printf '%-8s %s\n' "$check" "$("watch_check_$check" 2>&1 || echo "skipped: check failed")"
  done
  printf '%-8s %s\n' logs "$(watch_housekeeping 2>&1 || echo skipped)"
}

watch__unit_state() {
  local enabled active
  enabled=$(systemctl --user is-enabled "$WATCH_TIMER" 2>/dev/null || true)
  active=$(systemctl --user is-active "$WATCH_TIMER" 2>/dev/null || true)
  [[ -z $enabled || $enabled == not-found ]] && enabled=not-installed
  printf '%s %s\n' "$enabled" "${active:-inactive}"
}

cmd_watch() { cmd_watch_status "$@"; }

cmd_watch_status() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl watch status"
  local enabled active next
  read -r enabled active < <(watch__unit_state)
  next=$(systemctl --user show "$WATCH_TIMER" -p NextElapseUSecRealtime --value 2>/dev/null || true)
  if ((DEVCTL_JSON)); then
    jq -nc --arg e "$enabled" --arg a "$active" --arg n "$next" '{enabled: $e, active: $a, next_run: $n}'
    return 0
  fi
  {
    printf 'timer\t%s, %s\n' "$enabled" "$active"
    [[ -n $next && $next != n/a ]] && printf 'next check\t%s\n' "$next"
    printf 'checks\tdisk (≤ %s%% free), crashed containers, image updates (daily), old logs\n' "$(config_get guard.disk_min_free_percent)"
  } | ui_table
  [[ $enabled == enabled ]] || ui_note "turn it on with: devctl watch enable"
}

cmd_watch_enable() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl watch enable"
  local bin="$DEVCTL_ROOT/bin/devctl" content
  [[ $bin =~ ^[A-Za-z0-9/._+-]+$ ]] || die "$EX_PRECONDITION" "the repo path has characters a systemd unit cannot use"
  ui_header "Background checks (systemd user timer, ADR-0010)"
  printf '  %s\n' "every 30 minutes: disk space, crashed containers, image updates (once a day), old logs" \
    "it never starts Docker or anything else, and only notifies you" \
    "files: $WATCH_UNIT_DIR/devctl-watch.{service,timer}"
  confirm_or_abort "Turn on background checks? (it starts with your session; devctl watch disable turns it off)" yes
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "install devctl-watch.service and devctl-watch.timer; systemctl --user enable --now $WATCH_TIMER"
    return 0
  fi
  mkdir -p -- "$WATCH_UNIT_DIR"
  content=$(<"$DEVCTL_ROOT/share/systemd/user/devctl-watch.service.in")
  printf '%s\n' "${content//@DEVCTL_BIN@/$bin}" >"$WATCH_UNIT_DIR/devctl-watch.service"
  install -m 0644 -T -- "$DEVCTL_ROOT/share/systemd/user/devctl-watch.timer" "$WATCH_UNIT_DIR/devctl-watch.timer"
  run_change --desc "Reload user units" -- systemctl --user daemon-reload || die "$EX_EXTERNAL" "systemctl --user daemon-reload failed"
  run_change --desc "Enable the timer" -- systemctl --user enable --now "$WATCH_TIMER" || die "$EX_EXTERNAL" "could not enable the timer"
  ui_ok "Background checks are on (first check in about 5 minutes)"
}

cmd_watch_disable() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl watch disable"
  local enabled active
  read -r enabled active < <(watch__unit_state)
  if [[ $enabled == not-installed && ! -e $WATCH_UNIT_DIR/devctl-watch.timer ]]; then
    ui_skip "background checks are not installed"
    return 0
  fi
  run_change --desc "Disable the timer" -- systemctl --user disable --now "$WATCH_TIMER" || true
  run_change --desc "Remove unit files" -- rm -f -- "$WATCH_UNIT_DIR/devctl-watch.service" "$WATCH_UNIT_DIR/devctl-watch.timer"
  run_change --desc "Reload user units" -- systemctl --user daemon-reload || true
  ((DEVCTL_DRY_RUN)) || ui_ok "Background checks are off"
}

complete_watch() {
  [[ $1 == flags && $2 == tick ]] && printf '%s\n' --force
  return 0
}

help_watch() {
  cat <<'HELP'
Usage: devctl watch [status]        timer on/off and next check
       devctl watch enable          install and start the user timer (asks first)
       devctl watch disable         stop and remove it
       devctl watch tick [--force]  run the checks now (--force re-sends alerts)

Every 30 minutes: disk space (alert at guard.disk_min_free_percent, repeated at most every
6 h), devctl containers that crashed after their restarts, newer images for your servers
(once a day; devctl never updates anything by itself), and devctl logs older than
log.retention_days. Docker checks run only when Docker is already running. Alerts appear as
desktop notifications, in `devctl history --alerts` and live in the dashboard.
HELP
}
