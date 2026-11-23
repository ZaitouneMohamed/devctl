# shellcheck shell=bash
# notify.sh — desktop notifications (notify-send). Without a desktop session they are only
# logged; a notification is never required for devctl to work.

[[ -n ${__DEVCTL_NOTIFY_SH:-} ]] && return 0
__DEVCTL_NOTIFY_SH=1

# notify URGENCY TITLE BODY — URGENCY: low | normal | critical
notify() {
  local urgency=$1 title=$2 body=$3
  is_in_list "$urgency" low normal critical || die "$EX_FAIL" "bad urgency (bug)"
  log_info "notify ($urgency): $title — $body"
  command -v notify-send >/dev/null || return 0
  notify-send --app-name=devctl --icon=devctl --urgency="$urgency" -- "$title" "$body" 2>/dev/null || true
}
