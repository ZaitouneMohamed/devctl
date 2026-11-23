# shellcheck shell=bash
# lock.sh — named advisory locks (flock) so two devctl runs never change the same thing at once.
#
# A lock is held through an open file descriptor; the kernel releases it automatically
# when the process exits, even after a crash or kill -9.

[[ -n ${__DEVCTL_LOCK_SH:-} ]] && return 0
__DEVCTL_LOCK_SH=1

declare -gA __LOCK_FDS=() # lock name -> fd

lock__file() { printf '%s/locks/%s.lock\n' "$DEVCTL_RUN_DIR" "$1"; }

# lock_acquire NAME [TIMEOUT_SECONDS] — wait for the lock; die with EX_CONFLICT on timeout.
lock_acquire() {
  local name=$1 timeout=${2:-} file fd
  is_identifier "$name" || die "$EX_FAIL" "invalid lock name '$name' (bug)"
  [[ -z ${__LOCK_FDS[$name]:-} ]] || die "$EX_FAIL" "lock '$name' is already held by this process (bug)"
  if [[ -z $timeout ]]; then
    timeout=$(config_get lock.timeout_seconds)
  fi
  is_uint "$timeout" || die "$EX_FAIL" "invalid lock timeout '$timeout' (bug)"

  file=$(lock__file "$name")
  ensure_private_dir "${file%/*}"
  exec {fd}>>"$file"
  if ! flock -w "$timeout" "$fd"; then
    exec {fd}>&-
    die "$EX_CONFLICT" "another devctl run is busy with '$name' (waited ${timeout}s); try again later"
  fi
  __LOCK_FDS[$name]=$fd
  log_debug "lock acquired: $name"
}

# lock_release NAME — release a lock held by this process (no-op if not held).
lock_release() {
  local fd=${__LOCK_FDS[$1]:-}
  [[ -n $fd ]] || return 0
  flock -u "$fd"
  exec {fd}>&-
  unset '__LOCK_FDS[$1]'
  log_debug "lock released: $1"
}

# with_lock NAME -- COMMAND [ARGS...] — run COMMAND while holding NAME; return its status.
# Note: COMMAND runs on the left of `||`, where Bash disables errexit inside it, so
# COMMAND must check its own errors (devctl functions do, via die/return codes).
with_lock() {
  local name=$1 status=0
  shift
  [[ ${1:-} == -- ]] && shift
  lock_acquire "$name"
  "$@" || status=$?
  lock_release "$name"
  return "$status"
}
