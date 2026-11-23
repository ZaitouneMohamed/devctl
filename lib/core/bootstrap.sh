# shellcheck shell=bash
# bootstrap.sh — paths, globals and core library loading.
#
# Sourcing this file only defines globals and functions; it has no side effects on the
# filesystem and sets no traps, so tests can source it safely. The entry point calls
# devctl_init_runtime (from errors.sh) to switch on strict mode and traps.

[[ -n ${__DEVCTL_BOOTSTRAP_SH:-} ]] && return 0
__DEVCTL_BOOTSTRAP_SH=1

if ((BASH_VERSINFO[0] < 5)); then
  printf 'devctl: Bash 5 or newer is required (found %s)\n' "$BASH_VERSION" >&2
  exit 7
fi

: "${DEVCTL_ROOT:?DEVCTL_ROOT must be set before sourcing bootstrap.sh}"

# Every devctl path derives from $HOME; an empty or relative value would scatter files.
if [[ ${HOME:-} != /* ]]; then
  printf 'devctl: HOME must be an absolute path (got "%s")\n' "${HOME:-}" >&2
  exit 7
fi

DEVCTL_VERSION="0.1.0-dev"

# xdg_dir VAR DEFAULT — print $VAR if it is an absolute path, else DEFAULT.
# The XDG spec says relative values must be ignored.
xdg_dir() {
  local value=${!1:-}
  if [[ $value == /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$2"
  fi
}

DEVCTL_CONFIG_DIR="$(xdg_dir XDG_CONFIG_HOME "$HOME/.config")/devctl"
DEVCTL_DATA_DIR="$(xdg_dir XDG_DATA_HOME "$HOME/.local/share")/devctl"
DEVCTL_STATE_DIR="$(xdg_dir XDG_STATE_HOME "$HOME/.local/state")/devctl"
DEVCTL_CACHE_DIR="$(xdg_dir XDG_CACHE_HOME "$HOME/.cache")/devctl"
DEVCTL_LOG_DIR="$DEVCTL_STATE_DIR/logs"
DEVCTL_RUN_DIR="$DEVCTL_STATE_DIR/run"
DEVCTL_HISTORY_FILE="$DEVCTL_STATE_DIR/history.jsonl"
DEVCTL_CMD_DIR="$DEVCTL_ROOT/lib/cmd"

# ensure_private_dir DIR — create DIR and any missing parents as 0700 (mkdir -m would
# only apply the mode to the last component).
ensure_private_dir() {
  [[ -d $1 ]] || (umask 077 && mkdir -p -- "$1")
}

# Runtime switches. Set only by global flags (router.sh), never inherited from the
# environment, so a stray exported variable cannot silently enable --yes.
DEVCTL_DRY_RUN=0
DEVCTL_ASSUME_YES=0
DEVCTL_JSON=0
DEVCTL_QUIET=0
DEVCTL_VERBOSE=0
DEVCTL_CONFIRM_TEXT=""

# shellcheck source=lib/core/errors.sh
source "$DEVCTL_ROOT/lib/core/errors.sh"
# shellcheck source=lib/core/log.sh
source "$DEVCTL_ROOT/lib/core/log.sh"
# shellcheck source=lib/core/ui.sh
source "$DEVCTL_ROOT/lib/core/ui.sh"
# shellcheck source=lib/core/json.sh
source "$DEVCTL_ROOT/lib/core/json.sh"
# shellcheck source=lib/core/validate.sh
source "$DEVCTL_ROOT/lib/core/validate.sh"
# shellcheck source=lib/core/config.sh
source "$DEVCTL_ROOT/lib/core/config.sh"
# shellcheck source=lib/core/lock.sh
source "$DEVCTL_ROOT/lib/core/lock.sh"
# shellcheck source=lib/core/run.sh
source "$DEVCTL_ROOT/lib/core/run.sh"
# shellcheck source=lib/core/kv.sh
source "$DEVCTL_ROOT/lib/core/kv.sh"
# shellcheck source=lib/core/secret.sh
source "$DEVCTL_ROOT/lib/core/secret.sh"
# shellcheck source=lib/core/guard.sh
source "$DEVCTL_ROOT/lib/core/guard.sh"
# shellcheck source=lib/core/notify.sh
source "$DEVCTL_ROOT/lib/core/notify.sh"
# shellcheck source=lib/core/privilege.sh
source "$DEVCTL_ROOT/lib/core/privilege.sh"
# shellcheck source=lib/core/history.sh
source "$DEVCTL_ROOT/lib/core/history.sh"
# shellcheck source=lib/core/adapter.sh
source "$DEVCTL_ROOT/lib/core/adapter.sh"
# shellcheck source=lib/core/router.sh
source "$DEVCTL_ROOT/lib/core/router.sh"
