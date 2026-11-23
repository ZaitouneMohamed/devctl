# shellcheck shell=bash
# summary: Install, check or remove the privileged helper (asks for your sudo password)

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action root.install root.uninstall

root__policy_state() {
  if [[ ! -f $DEVCTL_POLKIT_POLICY ]]; then
    printf 'missing\n'
  elif cmp -s -- "$DEVCTL_POLKIT_POLICY" "$DEVCTL_ROOT/share/polkit/local.devctl.root.policy"; then
    printf 'ok\n'
  else
    printf 'outdated\n'
  fi
}

# Installing needs sudo directly (the helper cannot install itself).
root__require_terminal() {
  [[ -t 0 ]] || die "$EX_PRECONDITION" "run this in a terminal: it asks for your sudo password"
}

cmd_root() {
  cmd_root_status "$@"
}

cmd_root_status() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl root status"
  local helper policy
  helper=$(priv_helper_state)
  policy=$(root__policy_state)
  if ((DEVCTL_JSON)); then
    jq -nc --arg helper "$helper" --arg policy "$policy" \
      --arg helper_path "$DEVCTL_ROOT_HELPER" --arg policy_path "$DEVCTL_POLKIT_POLICY" \
      '{helper: {state: $helper, path: $helper_path}, polkit_policy: {state: $policy, path: $policy_path}}'
    return 0
  fi
  {
    printf 'ITEM\tSTATE\tPATH\n'
    printf 'helper\t%s\t%s\n' "$helper" "$DEVCTL_ROOT_HELPER"
    printf 'polkit-policy\t%s\t%s\n' "$policy" "$DEVCTL_POLKIT_POLICY"
  } | ui_table
  if [[ $helper != ok || $policy != ok ]]; then
    ui_note "install or update with: devctl root install"
  fi
}

cmd_root_install() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl root install"
  local helper policy
  helper=$(priv_helper_state)
  policy=$(root__policy_state)
  if [[ $helper == ok && $policy == ok ]]; then
    ui_skip "privileged helper and polkit policy are installed and up to date"
    return 0
  fi

  ui_header "Install the devctl privileged helper (as root, via sudo)"
  printf '%s\n' \
    "  helper        $DEVCTL_ROOT_HELPER   (root:root 0755)  — currently: $helper" \
    "  polkit policy $DEVCTL_POLKIT_POLICY  (root:root 0644)  — currently: $policy" \
    "  Review what will run as root first: $DEVCTL_ROOT/libexec/devctl-root"
  ((DEVCTL_DRY_RUN)) || root__require_terminal
  confirm_or_abort "Install them now? (sudo will ask for your password)"

  # install -Z gives the files the SELinux label their destination expects.
  if [[ $helper != ok ]]; then
    run_change --desc "Install helper" -- \
      sudo -- install -o root -g root -m 0755 -Z -T -- "$DEVCTL_ROOT/libexec/devctl-root" "$DEVCTL_ROOT_HELPER" ||
      die "$EX_PRIVILEGE" "could not install the helper"
  fi
  if [[ $policy != ok ]]; then
    run_change --desc "Install polkit policy" -- \
      sudo -- install -o root -g root -m 0644 -Z -T -- "$DEVCTL_ROOT/share/polkit/local.devctl.root.policy" "$DEVCTL_POLKIT_POLICY" ||
      die "$EX_PRIVILEGE" "could not install the polkit policy"
  fi
  ((DEVCTL_DRY_RUN)) && return 0

  [[ $(priv_helper_state) == ok ]] || die "$EX_FAIL" "helper installed but not in the expected state; check: devctl root status"
  ui_ok "Installed"
  cmd_root_test
}

# test: run the helper's self-test, proving the whole sudo/pkexec path works.
cmd_root_test() {
  local via=""
  case ${1:-} in
    "") ;;
    --polkit) via=pkexec ;;
    *) die "$EX_USAGE" "usage: devctl root test [--polkit]" ;;
  esac
  local output
  if [[ $via == pkexec ]]; then
    [[ $(priv_helper_state) == ok ]] || die "$EX_PRECONDITION" "helper not installed or outdated; run: devctl root install"
    ui_step "A password dialog should appear on your desktop"
    output=$(pkexec "$DEVCTL_ROOT_HELPER" self-test) || die "$EX_PRIVILEGE" "pkexec failed or was cancelled"
  else
    output=$(priv_run --desc "Helper self-test" self-test)
    ((DEVCTL_DRY_RUN)) && return 0
  fi
  [[ $output == "euid=0 caller_uid=$EUID "* ]] || die "$EX_FAIL" "unexpected self-test output: $output"
  ui_ok "Helper works: $output"
}

cmd_root_uninstall() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl root uninstall"
  local -a present=()
  [[ -e $DEVCTL_ROOT_HELPER ]] && present+=("$DEVCTL_ROOT_HELPER")
  [[ -e $DEVCTL_POLKIT_POLICY ]] && present+=("$DEVCTL_POLKIT_POLICY")
  if ((${#present[@]} == 0)); then
    ui_skip "nothing to remove"
    return 0
  fi
  ui_note "Without the helper, devctl cannot change hosts, web server or system settings."
  ((DEVCTL_DRY_RUN)) || root__require_terminal
  confirm_or_abort "Remove ${present[*]}?"
  run_change --desc "Remove helper files" -- sudo -- rm -f -- "${present[@]}" ||
    die "$EX_PRIVILEGE" "could not remove the files"
  ((DEVCTL_DRY_RUN)) || ui_ok "Removed"
}

complete_root() {
  [[ $1 == flags && $2 == test ]] && printf '%s\n' --polkit
  return 0
}

help_root() {
  cat <<'HELP'
Usage: devctl root [status]       is the helper installed and up to date?
       devctl root install        install/update it (asks for your sudo password)
       devctl root test [--polkit] check it works (--polkit: via the desktop password dialog)
       devctl root uninstall

Everything devctl does as root goes through one small, root-owned script:
  /usr/local/libexec/devctl-root   (source: libexec/devctl-root in the repo — read it!)
It accepts a fixed list of operations, checks every argument and logs every call:
  journalctl -t devctl-root
From the terminal it runs through sudo (password prompt); from the dashboard through
pkexec (desktop password dialog). devctl never adds passwordless sudo rules.
After the helper changes in the repo, `devctl root status` shows "outdated" until you
run `devctl root install` again.
HELP
}
