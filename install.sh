#!/usr/bin/env bash
# install.sh — install devctl for the current user (no sudo).
# Same as: bin/devctl self install [--force] [--no-desktop-icon] [--dry-run]
set -Eeuo pipefail
here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
exec "$here/bin/devctl" self install "$@"
