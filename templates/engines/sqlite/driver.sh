# shellcheck shell=bash
# SQLite driver: the database is a file in the project; created by `devctl site create`.
sqlite_create_file() { # PATH
  [[ -e $1 ]] && return 0
  run_change --desc "Create SQLite database" -- touch -- "$1"
}
