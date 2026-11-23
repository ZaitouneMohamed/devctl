# shellcheck shell=bash
# PostgreSQL driver. Root work runs as the "postgres" superuser over the container's local
# socket (trusted inside the official image). Names validated by the caller.

postgres_root_sql() { # CONTAINER [DB] — SQL from stdin, unaligned tuples-only output
  ce_exec "$1" -- psql -U postgres -v ON_ERROR_STOP=1 -qAt -d "${2:-postgres}"
}

postgres_create() { # CONTAINER DB USER PASSWORD
  local c=$1 db=$2 user=$3 pass=$4
  printf "SELECT 'CREATE ROLE \"%s\" LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s')\\\\gexec
ALTER ROLE \"%s\" WITH LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEDB NOCREATEROLE;
SELECT 'CREATE DATABASE \"%s\" OWNER \"%s\"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '%s')\\\\gexec
REVOKE ALL ON DATABASE \"%s\" FROM PUBLIC;\n" \
    "$user" "$user" "$user" "$pass" "$db" "$user" "$db" "$db" | postgres_root_sql "$c"
  # pgvector must be enabled by a superuser, once per database.
  printf 'CREATE EXTENSION IF NOT EXISTS vector;\n' | postgres_root_sql "$c" "$db"
}

postgres_drop() { # CONTAINER DB USER — the database (closing its connections) and its role
  printf 'DROP DATABASE IF EXISTS "%s" WITH (FORCE);\nDROP ROLE IF EXISTS "%s";\n' "$2" "$3" | postgres_root_sql "$1"
}

postgres_is_empty() { # CONTAINER DB
  local n
  n=$(printf "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema');\n" | postgres_root_sql "$1" "$2")
  [[ $n == 0 ]]
}

postgres_shell() { # CONTAINER DB USER PASSWORD
  PGPASSWORD=$4 ce_exec_tty --env PGPASSWORD "$1" -- psql -h 127.0.0.1 -U "$3" -d "$2"
}

postgres_root_shell() { ce_exec_tty "$1" -- psql -U postgres; }

postgres_dump() { # CONTAINER DB → custom-format dump on stdout
  ce_exec "$1" -- pg_dump -U postgres --format=custom --no-owner -d "$2"
}

# Objects are restored owned by the project user. Custom-format dumps: extension entries are
# skipped (only a superuser may restore them; `db create` already enabled pgvector).
# Plain SQL dumps run through psql as the project user.
postgres_restore() { # CONTAINER DB USER ← custom-format dump on stdin
  ce_exec "$1" -- sh -c '
    set -e
    dump=$(mktemp) list=$(mktemp)
    trap "rm -f \"\$dump\" \"\$list\"" EXIT
    cat >"$dump"
    if [ "$(head -c 5 "$dump")" = PGDMP ]; then
      pg_restore -l "$dump" | grep -v -E " (EXTENSION|COMMENT) - (EXTENSION )?[a-z_]+ ?" >"$list" || true
      pg_restore -U postgres --no-owner --role="$2" -d "$1" -L "$list" "$dump"
    else
      # Plain SQL (pg_dump without -Fc, or other tools): run it as the project user, so the
      # tables belong to the project (local connections inside the container are trusted).
      psql -v ON_ERROR_STOP=1 -q -U "$2" -d "$1" -f "$dump"
    fi
  ' sh "$2" "$3"
}
