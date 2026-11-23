# shellcheck shell=bash
# summary: Show the devctl version

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

cmd_version() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl version"
  if ((DEVCTL_JSON)); then
    jq -nc --arg version "$DEVCTL_VERSION" '{version: $version}'
  else
    printf 'devctl %s\n' "$DEVCTL_VERSION"
  fi
}

help_version() {
  cat <<'EOF'
Usage: devctl version [--json]

Print the devctl version.
EOF
}
