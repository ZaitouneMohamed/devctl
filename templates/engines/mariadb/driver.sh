# shellcheck shell=bash
# MariaDB driver: the MySQL-family driver with flavor "mariadb".
# shellcheck source=templates/engines/mysql/driver.sh
source "$DEVCTL_ROOT/templates/engines/mysql/driver.sh"

mariadb_create() { mysqlish_create mariadb "$@"; }
mariadb_drop() { mysqlish_drop mariadb "$@"; }
mariadb_is_empty() { mysqlish_is_empty mariadb "$@"; }
mariadb_shell() { mysqlish_shell mariadb "$@"; }
mariadb_root_shell() { mysqlish_root_shell mariadb "$@"; }
mariadb_dump() { mysqlish_dump mariadb "$@"; }
mariadb_restore() { mysqlish_restore mariadb "$@"; }
