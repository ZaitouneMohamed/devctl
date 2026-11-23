# shellcheck shell=bash
# MySQL-family driver (MySQL and MariaDB share the SQL; MariaDB has its own binaries and
# root variable). Root commands run inside the container using the root password the
# container already has in its environment: no secret ever appears on a command line.
# Database and user names are validated by the caller ([a-z][a-z0-9_]{0,31}); generated
# passwords are letters and digits only, so they are safe inside the SQL text.

# mysqlish__bin FLAVOR TOOL — client | dump | admin binary for the flavor.
mysqlish__bin() {
  case $1:$2 in
    mysql:client) printf 'mysql\n' ;;
    mysql:dump) printf 'mysqldump\n' ;;
    mariadb:client) printf 'mariadb\n' ;;
    mariadb:dump) printf 'mariadb-dump\n' ;;
    *) die "$EX_FAIL" "unknown mysql flavor '$1' (bug)" ;;
  esac
}

mysqlish__root_env() {
  case $1 in
    mysql) printf 'MYSQL_ROOT_PASSWORD\n' ;;
    mariadb) printf 'MARIADB_ROOT_PASSWORD\n' ;;
  esac
}

# mysqlish_root_sql FLAVOR CONTAINER — run SQL from stdin as root, plain output.
mysqlish_root_sql() {
  local bin env
  bin=$(mysqlish__bin "$1" client)
  env=$(mysqlish__root_env "$1")
  ce_exec "$2" -- sh -c "MYSQL_PWD=\"\$$env\" exec $bin -uroot --batch --skip-column-names"
}

mysqlish_create() { # FLAVOR CONTAINER DB USER PASSWORD
  printf "CREATE DATABASE IF NOT EXISTS \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';
ALTER USER '%s'@'%%' IDENTIFIED BY '%s';
GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\n" \
    "$3" "$4" "$5" "$4" "$5" "$3" "$4" | mysqlish_root_sql "$1" "$2"
}

mysqlish_drop() { # FLAVOR CONTAINER DB USER — the database (all its tables) and its user
  printf "DROP DATABASE IF EXISTS \`%s\`;\nDROP USER IF EXISTS '%s'@'%%';\n" "$3" "$4" | mysqlish_root_sql "$1" "$2"
}

mysqlish_is_empty() { # FLAVOR CONTAINER DB
  local n
  n=$(printf "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '%s';\n" "$3" | mysqlish_root_sql "$1" "$2")
  [[ $n == 0 ]]
}

mysqlish_shell() { # FLAVOR CONTAINER DB USER PASSWORD — password via the environment only
  MYSQL_PWD=$5 ce_exec_tty --env MYSQL_PWD "$2" -- "$(mysqlish__bin "$1" client)" "-u$4" -- "$3"
}

mysqlish_root_shell() { # FLAVOR CONTAINER
  ce_exec_tty "$2" -- sh -c "MYSQL_PWD=\"\$$(mysqlish__root_env "$1")\" exec $(mysqlish__bin "$1" client) -uroot"
}

mysqlish_dump() { # FLAVOR CONTAINER DB → SQL on stdout
  ce_exec "$2" -- sh -c "MYSQL_PWD=\"\$$(mysqlish__root_env "$1")\" exec $(mysqlish__bin "$1" dump) -uroot --single-transaction --routines --triggers --no-tablespaces -- \"\$1\"" sh "$3"
}

mysqlish_restore() { # FLAVOR CONTAINER DB ← SQL on stdin
  ce_exec "$2" -- sh -c "MYSQL_PWD=\"\$$(mysqlish__root_env "$1")\" exec $(mysqlish__bin "$1" client) -uroot -- \"\$1\"" sh "$3"
}

mysql_create() { mysqlish_create mysql "$@"; }
mysql_drop() { mysqlish_drop mysql "$@"; }
mysql_is_empty() { mysqlish_is_empty mysql "$@"; }
mysql_shell() { mysqlish_shell mysql "$@"; }
mysql_root_shell() { mysqlish_root_shell mysql "$@"; }
mysql_dump() { mysqlish_dump mysql "$@"; }
mysql_restore() { mysqlish_restore mysql "$@"; }
