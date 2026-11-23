# shellcheck shell=bash
# summary: Show, start or stop the container engine (Docker)

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action engine.start engine.stop
adapter_load engine

cmd_engine() {
  cmd_engine_status "$@"
}

cmd_engine_status() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl engine status"
  local running=false boot=false version="" managed=0 total=0
  ce_daemon_running && running=true
  ce_daemon_enabled_at_boot && boot=true
  version=$(ce_version || true)
  if [[ $running == true ]]; then
    managed=$(ce_managed_containers | grep -c . || true)
    total=$(ce_running_count)
  fi
  if ((DEVCTL_JSON)); then
    jq -nc --arg engine "$(ce_name)" --arg version "$version" --argjson running "$running" \
      --argjson boot "$boot" --argjson managed "$managed" --argjson total "$total" \
      '{engine: $engine, version: $version, running: $running, starts_at_boot: $boot,
        devctl_containers: $managed, running_containers: $total}'
    return 0
  fi
  {
    printf 'engine\t%s %s\n' "$(ce_name)" "${version:-(not installed)}"
    printf 'running\t%s\n' "$([[ $running == true ]] && echo yes || echo no)"
    printf 'starts at boot\t%s\n' "$([[ $boot == true ]] && echo 'yes (devctl doctor can fix this)' || echo no)"
    [[ $running == true ]] && printf 'containers\t%s running (%s managed by devctl)\n' "$total" "$managed"
  } | ui_table
}

cmd_engine_start() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl engine start"
  if ce_daemon_running; then
    ui_skip "Docker is already running"
    return 0
  fi
  ce_ensure_running
}

cmd_engine_stop() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl engine stop"
  if ! ce_daemon_running; then
    ui_skip "Docker is not running"
    return 0
  fi
  local count
  count=$(ce_running_count)
  if ((count > 0)); then
    confirm_or_abort "Stop Docker? $count running container(s) will stop."
  fi
  ce_daemon_stop || die "$EX_EXTERNAL" "could not stop Docker"
  ((DEVCTL_DRY_RUN)) || ui_ok "Docker stopped"
}

help_engine() {
  cat <<'HELP'
Usage: devctl engine [status]   engine, version, running, starts at boot, containers
       devctl engine start      start Docker (sudo password; devctl also does this when needed)
       devctl engine stop       stop Docker and its socket (asks if containers are running)

Docker does not start at boot. devctl starts it when a command needs it.
Engine setting: engine.adapter (docker).
HELP
}
