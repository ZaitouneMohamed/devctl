# shellcheck shell=bash
# guard.sh — warnings before heavy work: low memory (RAM) before starting heavy services.

[[ -n ${__DEVCTL_GUARD_SH:-} ]] && return 0
__DEVCTL_GUARD_SH=1

# guard__meminfo — "AVAILABLE_KB TOTAL_KB" from /proc/meminfo. MemAvailable already
# accounts for memory used by running VMware VMs (they are ordinary processes).
guard__meminfo() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {print a, t}' /proc/meminfo
}

# guard_memory WHAT — warn and ask if available RAM is below guard.memory_min_available_percent.
guard_memory() {
  local what=$1 avail total pct limit
  read -r avail total < <(guard__meminfo)
  is_uint "$avail" && is_uint "$total" && ((total > 0)) || return 0
  pct=$((avail * 100 / total))
  limit=$(config_get guard.memory_min_available_percent)
  ((pct >= limit)) && return 0
  ui_note "Only $((avail / 1024)) MiB of RAM available (${pct}%, warning below ${limit}%). Starting $what may slow the laptop down."
  confirm_or_abort "Start $what anyway?"
}
