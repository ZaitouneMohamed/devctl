# shellcheck shell=bash
# privilege.sh — the only way devctl does anything as root: run a verb of the installed,
# root-owned helper through sudo (terminal: password prompt) or pkexec (dashboard: the
# desktop's graphical password dialog). No passwordless rules are ever installed.

[[ -n ${__DEVCTL_PRIVILEGE_SH:-} ]] && return 0
__DEVCTL_PRIVILEGE_SH=1

# Not readonly so tests can point it at a fake helper.
DEVCTL_ROOT_HELPER=/usr/local/libexec/devctl-root
DEVCTL_POLKIT_POLICY=/usr/share/polkit-1/actions/local.devctl.root.policy

# priv_helper_state — ok | missing | outdated | insecure
#   outdated: differs from libexec/devctl-root in the repo (run `devctl root install`)
#   insecure: not owned by root, or writable by group/others → never used
priv_helper_state() {
  local owner mode
  [[ -f $DEVCTL_ROOT_HELPER ]] || { printf 'missing\n'; return 0; }
  read -r owner mode < <(stat -c '%u %a' -- "$DEVCTL_ROOT_HELPER")
  if ((owner != 0 || (8#$mode & 8#022) != 0)); then
    printf 'insecure\n'
  elif ! cmp -s -- "$DEVCTL_ROOT_HELPER" "$DEVCTL_ROOT/libexec/devctl-root"; then
    printf 'outdated\n'
  else
    printf 'ok\n'
  fi
}

# priv_launcher — sudo in a terminal; pkexec (desktop password dialog) for the dashboard,
# or when started without a terminal from the desktop (e.g. the dashboard icon).
priv_launcher() {
  if [[ $(history_source) == dashboard ]] || { [[ ! -t 0 ]] && [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; }; then
    printf 'pkexec\n'
  else
    printf 'sudo\n'
  fi
}

# priv_run [--desc TEXT] VERB [ARGS...] — run a helper verb as root. Goes through
# run_change, so --dry-run shows the exact command. Returns the verb's exit status.
priv_run() {
  local desc="" state launcher status=0
  if [[ ${1:-} == --desc ]]; then
    desc=$2
    shift 2
  fi
  (($#)) || die "$EX_FAIL" "priv_run: no verb given (bug)"

  state=$(priv_helper_state)
  # A dry run should still show the plan; the note says what a real run would need first.
  if ((DEVCTL_DRY_RUN)) && [[ $state == missing || $state == outdated ]]; then
    ui_note "the privileged helper is $state; a real run needs 'devctl root install' first"
    state=ok
  fi
  case $state in
    ok) ;;
    missing) die "$EX_PRECONDITION" "the privileged helper is not installed; run: devctl root install" ;;
    outdated) die "$EX_PRECONDITION" "the privileged helper is out of date; run: devctl root install" ;;
    insecure) die "$EX_PRIVILEGE" "$DEVCTL_ROOT_HELPER is not owned by root or is writable by others; refusing to use it (reinstall with: devctl root install)" ;;
  esac

  launcher=$(priv_launcher)
  if ((!DEVCTL_DRY_RUN)) && [[ $launcher == sudo && ! -t 0 ]] && ! sudo -n true 2>/dev/null; then
    die "$EX_PRIVILEGE" "administrator rights needed but there is no terminal for the sudo password"
  fi
  # sudo takes "--" before the program; pkexec does not (it would try to run "--"). The
  # helper path is absolute and fixed, so neither can mistake it for an option.
  local -a cmd=("$launcher" -- "$DEVCTL_ROOT_HELPER" "$@")
  [[ $launcher == pkexec ]] && cmd=(pkexec "$DEVCTL_ROOT_HELPER" "$@")
  run_change --desc "${desc:-As administrator: $1}" -- "${cmd[@]}" || status=$?
  case $status in
    0) return 0 ;;
    77) die "$EX_PRIVILEGE" "the privileged helper refused the request (details: journalctl -t devctl-root)" ;;
    126) die "$EX_PRIVILEGE" "administrator authentication was cancelled" ;;
    127) die "$EX_PRIVILEGE" "administrator authentication failed" ;;
    *) return "$status" ;;
  esac
}
