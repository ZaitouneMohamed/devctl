# shellcheck shell=bash
# summary: Show help for devctl or for one command

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

cmd_help() {
  (($# <= 1)) || die "$EX_USAGE" "usage: devctl help [command]"
  if (($# == 1)); then
    router_help_for "$1"
  else
    router_usage
  fi
}

help_help() {
  cat <<'EOF'
Usage: devctl help [command]

Without a command, list all commands and global options.
With a command, show that command's usage. Same as: devctl <command> --help
EOF
}

complete_help() {
  [[ $1 == args && $3 == 1 ]] && router_commands
  return 0
}
