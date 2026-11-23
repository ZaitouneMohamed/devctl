# shellcheck shell=bash
# summary: Database servers and databases (MySQL, MariaDB, PostgreSQL, MongoDB, Qdrant, Redis)

# shellcheck source=lib/services/dbservers.sh
source "${DEVCTL_ROOT:?}/lib/services/dbservers.sh"

register_action db.add db.start db.stop db.create db.import db.drop db.legacy-remove

readonly DB_LEGACY_DIR="$HOME/Desktop/projects/databases"

# db__opt NAME VALUE — shared option parsing helper for "--name value" / "--name=value".
# Usage in a loop: case $1 in --engine|--engine=*) db__take engine "$@"; shift "$DB_SHIFT" ;;
DB_SHIFT=1
db__take() {
  local -n __out=$1
  if [[ $2 == *=* ]]; then
    __out=${2#*=}
    DB_SHIFT=1
  else
    (($# >= 3)) || die "$EX_USAGE" "$2 needs a value"
    __out=$3
    DB_SHIFT=2
  fi
}

db__server_label() { # ID → "MySQL 8.4"
  local -A srv=() conf=()
  db_server_get "$1" srv || { printf '%s\n' "$1"; return; }
  dbe_load "${srv[engine]}" conf
  printf '%s %s\n' "${conf[name]}" "${srv[major]}"
}

cmd_db() { cmd_db_list "$@"; }

cmd_db_engines() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl db engines"
  local -A conf=()
  {
    local eng
    printf 'ENGINE\tNAME\tVERSIONS\tDEFAULT\tUSERS PER PROJECT\n'
    while IFS= read -r eng; do
      dbe_load "$eng" conf
      printf '%s\t%s\t%s\t%s\t%s\n' "$eng" "${conf[name]}" "${conf[majors]}" "${conf[default_major]}" "${conf[per_project_users]:-no}"
    done < <(dbe_engines)
  } | ui_table
}

cmd_db_list() {
  local show_dbs=0 id rows=()
  case ${1:-} in
    "") ;;
    --databases) show_dbs=1 ;;
    *) die "$EX_USAGE" "usage: devctl db list [--databases]" ;;
  esac
  if ((show_dbs)); then
    if ((DEVCTL_JSON)); then
      if [[ -s $DB_DATABASES_FILE ]]; then
        # which sites use each database (a database can be shared)
        local f users="{}"
        for f in "$DEVCTL_DATA_DIR"/registry/sites/*.conf; do
          [[ -f $f ]] || continue
          users=$(jq -c --arg site "$(sed -n 's/^name = //p' "$f")" --arg db "$(sed -n 's/^db_name = //p' "$f")" \
            --arg srv "$(sed -n 's/^db_server = //p' "$f")" \
            'if $db == "" then . else .[$srv + "/" + $db] += [$site] end' <<<"$users")
        done
        jq -R -s --argjson users "$users" 'split("\n") | map(select(length > 0) | split("\t")
          | {name: .[0], server: .[1], user: .[2], created: .[3], sites: ($users[.[1] + "/" + .[0]] // [])})' "$DB_DATABASES_FILE"
      else
        printf '[]\n'
      fi
      return 0
    fi
    [[ -s $DB_DATABASES_FILE ]] || { ui_skip "no databases yet (devctl db create NAME --engine ENGINE)"; return 0; }
    { printf 'DATABASE\tSERVER\tUSER\tCREATED\n'; cat -- "$DB_DATABASES_FILE"; } | ui_table
    return 0
  fi
  local -A srv=()
  local -a dbs=()
  mapfile -t dbs < <(dbe_engines database)
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    db_server_get "$id" srv
    is_in_list "${srv[engine]}" "${dbs[@]}" || continue
    rows+=("$id" "$(db__server_label "$id")" "${srv[port]}" "$(db_server_state "$id")" "$(db_refcount "$id")")
  done < <(db_server_ids)
  if ((DEVCTL_JSON)); then
    jq -n --argjson r "$(json_array "${rows[@]}")" \
      '[range(0; $r | length; 5) as $i | {id: $r[$i], engine: $r[$i + 1], port: ($r[$i + 2] | tonumber), state: $r[$i + 3], users: ($r[$i + 4] | tonumber)}]'
    return 0
  fi
  if ((${#rows[@]} == 0)); then
    ui_skip "no servers yet (devctl db create NAME --engine ENGINE, or devctl db add ENGINE)"
    return 0
  fi
  {
    printf 'SERVER\tENGINE\tPORT\tSTATE\tUSED BY\n'
    for ((i = 0; i < ${#rows[@]}; i += 5)); do
      printf '%s\t%s\t127.0.0.1:%s\t%s\t%s site(s)\n' "${rows[@]:i:5}"
    done
  } | ui_table
}

cmd_db_add() {
  local engine="" version="" any=""
  while (($#)); do
    case $1 in
      --version | --version=*) db__take version "$@"; shift "$DB_SHIFT" ;;
      --any-port) any=--any-port; shift ;;
      -*) die "$EX_USAGE" "usage: devctl db add ENGINE [--version V] [--any-port]" ;;
      *) [[ -z $engine ]] || die "$EX_USAGE" "one engine at a time"; engine=$1; shift ;;
    esac
  done
  [[ -n $engine ]] || die "$EX_USAGE" "usage: devctl db add ENGINE [--version V] [--any-port]"
  local id
  id=$(db_server_add "$engine" "$version" "$any")
  local -A srv=()
  if db_server_get "$id" srv; then
    ui_ok "Server $id: $(db__server_label "$id") on 127.0.0.1:${srv[port]} (this port never changes)"
  fi
}

cmd_db_start() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl db start SERVER"
  db_server_start "$1"
  ((DEVCTL_DRY_RUN)) || ui_ok "$1 is running"
}

cmd_db_stop() {
  local id="" force=0
  for arg; do
    case $arg in
      --force) force=1 ;;
      -*) die "$EX_USAGE" "usage: devctl db stop SERVER [--force]" ;;
      *) id=$arg ;;
    esac
  done
  [[ -n $id ]] || die "$EX_USAGE" "usage: devctl db stop SERVER [--force]"
  local -A srv=()
  db_server_get "$id" srv || die "$EX_NOTFOUND" "unknown server '$id'"
  local users
  users=$(db_refcount "$id")
  if ((users > 0 && !force)); then
    die "$EX_CONFLICT" "$id is used by running site(s): $(db_server_holders "$id" | paste -sd' '); stop them first, or use --force"
  fi
  db_server_stop "$id"
  ((force)) && db__holders_clear "$id"
  ((DEVCTL_DRY_RUN)) || ui_ok "$id stopped"
}

cmd_db_create() {
  local name="" engine="" version="" server=""
  while (($#)); do
    case $1 in
      --engine | --engine=*) db__take engine "$@"; shift "$DB_SHIFT" ;;
      --version | --version=*) db__take version "$@"; shift "$DB_SHIFT" ;;
      --server | --server=*) db__take server "$@"; shift "$DB_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl db create NAME --engine ENGINE [--version V]" ;;
      *) name=$1; shift ;;
    esac
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl db create NAME --engine ENGINE [--version V]"
  db_name_valid "$name" || die "$EX_VALIDATION" "invalid database name '$name': lowercase letters, digits and _, starting with a letter, max 32"
  local -A conf=() srv=()
  if [[ -n $server ]]; then
    db_server_get "$server" srv || die "$EX_NOTFOUND" "unknown server '$server' (see: devctl db list)"
    engine=${srv[engine]}
  fi
  [[ -n $engine ]] || die "$EX_USAGE" "which engine? add --engine (see: devctl db engines)"
  [[ $engine == sqlite ]] && die "$EX_USAGE" "SQLite databases are files inside a project; devctl site create makes them"
  dbe_load "$engine" conf
  if ! bool_true "${conf[per_project_users]:-no}"; then
    die "$EX_USAGE" "${conf[name]} has no databases or users to create; projects share the server (devctl db add $engine, then devctl db creds --server SERVER)"
  fi
  [[ -n $server ]] || server=$(db_server_add "$engine" "$version")
  if ((DEVCTL_DRY_RUN)) && ! db_server_get "$server" srv; then
    ui_plan "start server $server"
    ui_plan "create database '$name' and user '$name' (new password) on $server"
    return 0
  fi
  db_server_get "$server" srv
  db_server_start "$server"
  db_database_create "$server" "$name"
  ((DEVCTL_DRY_RUN)) && return 0
  ui_ok "Database '$name' with user '$name' on $(db__server_label "$server") (127.0.0.1:${srv[port]})"
  ui_note "connection details: devctl db creds $name"
}

cmd_db_creds() {
  local name="" server=""
  while (($#)); do
    case $1 in
      --server | --server=*) db__take server "$@"; shift "$DB_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl db creds NAME | --server SERVER" ;;
      *) name=$1; shift ;;
    esac
  done
  local -A srv=()
  local file user="" pass="" database=""
  if [[ -n $name ]]; then
    server=$(db_database_resolve "$name" "$server")
    db_server_get "$server" srv
    file=$(db_database_secrets "$server" "$name")
    database=$(secret_get "$file" DB_DATABASE)
    user=$(secret_get "$file" DB_USERNAME)
    pass=$(secret_get "$file" DB_PASSWORD)
  else
    [[ -n $server ]] || die "$EX_USAGE" "usage: devctl db creds NAME | --server SERVER"
    db_server_get "$server" srv || die "$EX_NOTFOUND" "unknown server '$server'"
  fi
  if ((DEVCTL_JSON)); then
    jq -nc --arg engine "${srv[engine]}" --argjson port "${srv[port]}" --arg database "$database" \
      --arg user "$user" --arg password "$pass" \
      '{engine: $engine, host: "127.0.0.1", port: $port, database: $database, username: $user, password: $password}'
    return 0
  fi
  [[ -t 1 ]] && ui_note "contains a password: do not paste it into chats, tickets or commits"
  {
    printf 'engine\t%s\n' "$(db__server_label "${srv[id]}")"
    printf 'host\t127.0.0.1\n'
    printf 'port\t%s\n' "${srv[port]}"
    [[ -n $database ]] && printf 'database\t%s\n' "$database"
    [[ -n $user ]] && printf 'username\t%s\n' "$user"
    [[ -n $pass ]] && printf 'password\t%s\n' "$pass"
    [[ ${srv[engine]} == qdrant ]] && printf 'dashboard\thttp://127.0.0.1:%s/dashboard (API key: devctl db root %s --show-key)\n' "${srv[port]}" "${srv[id]}"
  } | ui_table
}

cmd_db_shell() {
  local name="" server=""
  while (($#)); do
    case $1 in
      --server | --server=*) db__take server "$@"; shift "$DB_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl db shell NAME [--server SERVER]" ;;
      *) name=$1; shift ;;
    esac
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl db shell NAME [--server SERVER]"
  local -A srv=()
  if db_server_get "$name" srv && [[ ${srv[engine]} == redis ]]; then
    db_server_start "$name"
    dbe_call redis shell "$(db_server_container "$name")"
    return
  fi
  server=$(db_database_resolve "$name" "$server")
  db_server_get "$server" srv
  local file
  file=$(db_database_secrets "$server" "$name")
  db_server_start "$server"
  dbe_call "${srv[engine]}" shell "$(db_server_container "$server")" "$name" \
    "$(secret_get "$file" DB_USERNAME)" "$(secret_get "$file" DB_PASSWORD)"
}

# root: an explicit, separate command for superuser access (requirements §3.5).
cmd_db_root() {
  local server="" show_key=0
  for arg; do
    case $arg in
      --show-key) show_key=1 ;;
      -*) die "$EX_USAGE" "usage: devctl db root SERVER [--show-key]" ;;
      *) server=$arg ;;
    esac
  done
  local -A srv=() conf=()
  db_server_get "$server" srv || die "$EX_NOTFOUND" "usage: devctl db root SERVER (see: devctl db list)"
  dbe_load "${srv[engine]}" conf
  if ((show_key)); then
    [[ -n ${conf[root_secret]:-} ]] || die "$EX_USAGE" "${conf[name]} has no root secret"
    secret_get "$(db_server_secrets "$server")" "${conf[root_secret]}"
    return 0
  fi
  ui_note "superuser access to $(db__server_label "$server"): every database on it"
  db_server_start "$server"
  dbe_call "${srv[engine]}" root_shell "$(db_server_container "$server")"
}

db__dump_ext() {
  case $1 in
    postgres) printf 'dump\n' ;;
    mongodb) printf 'archive\n' ;;
    *) printf 'sql\n' ;;
  esac
}

cmd_db_export() {
  local name="" server="" file=""
  while (($#)); do
    case $1 in
      --server | --server=*) db__take server "$@"; shift "$DB_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl db export NAME [FILE.gz]" ;;
      *) if [[ -z $name ]]; then name=$1; else file=$1; fi; shift ;;
    esac
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl db export NAME [FILE.gz]"
  server=$(db_database_resolve "$name" "$server")
  local -A srv=()
  db_server_get "$server" srv
  dbe_supports "${srv[engine]}" dump || die "$EX_USAGE" "${srv[engine]} has no export"
  [[ -n $file ]] || file="$PWD/$name-${srv[engine]}-$(date +%Y%m%d-%H%M%S).$(db__dump_ext "${srv[engine]}").gz"
  [[ $file == *.gz ]] || file+=.gz
  [[ -e $file ]] && die "$EX_CONFLICT" "$file already exists"
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "export $name from $server to $file (gzip)"
    return 0
  fi
  db_server_start "$server"
  local partial="$file.partial"
  if dbe_call "${srv[engine]}" dump "$(db_server_container "$server")" "$name" | gzip -c >"$partial"; then
    mv -f -- "$partial" "$file"
    ui_ok "Exported $name → $file ($(du -h -- "$file" | cut -f1))"
  else
    rm -f -- "$partial"
    die "$EX_EXTERNAL" "export failed; nothing was written"
  fi
}

# drop NAME — delete a database nobody uses any more (type its name to confirm).
cmd_db_drop() {
  local name="" server="" users
  while (($#)); do
    case $1 in
      --server | --server=*) db__take server "$@"; shift "$DB_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl db drop NAME [--server SERVER]" ;;
      *) [[ -z $name ]] || die "$EX_USAGE" "usage: devctl db drop NAME [--server SERVER]"; name=$1; shift ;;
    esac
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl db drop NAME [--server SERVER]"
  server=$(db_database_resolve "$name" "$server")
  users=$(db_database_sites "$server" "$name" | paste -sd, - || true)
  [[ -z $users ]] || die "$EX_CONFLICT" "$name is used by ${users//,/, }; delete those sites first (devctl site delete NAME --with-db)"
  ui_header "Delete the database $name on $server"
  printf '  %s\n' "DELETED: every table and all data in $name, its user and saved password" \
    "tip: keep a copy first with: devctl db export $name"
  confirm_typed "$name" || die "$EX_ABORTED" "aborted; nothing changed"
  db_database_drop "$server" "$name"
  ((DEVCTL_DRY_RUN)) || ui_ok "database $name deleted"
}

cmd_db_import() {
  local name="" server="" file=""
  while (($#)); do
    case $1 in
      --server | --server=*) db__take server "$@"; shift "$DB_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl db import NAME FILE[.gz]" ;;
      *) if [[ -z $name ]]; then name=$1; else file=$1; fi; shift ;;
    esac
  done
  [[ -n $name && -n $file ]] || die "$EX_USAGE" "usage: devctl db import NAME FILE[.gz]"
  [[ -r $file ]] || die "$EX_NOTFOUND" "cannot read $file"
  server=$(db_database_resolve "$name" "$server")
  local -A srv=()
  db_server_get "$server" srv
  dbe_supports "${srv[engine]}" restore || die "$EX_USAGE" "${srv[engine]} has no import"
  local container
  container=$(db_server_container "$server")
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "import $file into $name on $server (asks to type '$name' if it is not empty)"
    return 0
  fi
  db_server_start "$server"
  if ! dbe_call "${srv[engine]}" is_empty "$container" "$name"; then
    ui_note "database '$name' already has tables/collections; importing adds to or overwrites them"
    confirm_typed "$name" || die "$EX_ABORTED" "aborted; nothing imported"
  fi
  local -a reader=(cat --)
  [[ $file == *.gz ]] && reader=(gzip -dc --)
  local user
  user=$(secret_get "$(db_database_secrets "$server" "$name")" DB_USERNAME)
  "${reader[@]}" "$file" | dbe_call "${srv[engine]}" restore "$container" "$name" "$user" ||
    die "$EX_EXTERNAL" "import failed (the database may be partly imported)"
  ui_ok "Imported $file into $name"
}

# legacy-remove: the old ~/Desktop/projects/databases setup (ADR-0016).
cmd_db_legacy_remove() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl db legacy-remove"
  local compose="$DB_LEGACY_DIR/compose.yaml" twin="$DB_LEGACY_DIR/compose.yam"
  if [[ ! -e $compose && ! -e $twin ]]; then
    ui_skip "the old setup in $DB_LEGACY_DIR is already gone"
    return 0
  fi
  ui_header "Remove the old database setup (ADR-0016)"
  printf '%s\n' \
    "  containers dev-mysql (mysql:8.4) and dev-postgres (postgres:17), their network," \
    "  their volumes databases_mysql_data and databases_postgres_data — ALL DATA IN THEM IS DELETED," \
    "  and the files $compose and $twin." \
    "  The folder $DB_LEGACY_DIR itself is kept."
  confirm_typed legacy "the old databases" || die "$EX_ABORTED" "aborted; nothing removed"
  if [[ -e $compose ]]; then
    ce_ensure_running
    ce_compose_purge databases "$compose" || die "$EX_EXTERNAL" "could not remove the old containers"
  fi
  local f
  for f in "$compose" "$twin"; do
    [[ -e $f ]] && run_change --desc "Delete" -- rm -f -- "$f"
  done
  ((DEVCTL_DRY_RUN)) || ui_ok "Old setup removed; ports 3306 and 5432 are free for devctl's servers"
}

complete_db() {
  case $1:$2 in
    args:add | args:create) [[ $3 == 1 && $2 == add ]] && dbe_engines ;;
    args:start | args:stop | args:root) [[ $3 == 1 ]] && db_server_ids ;;
    args:shell | args:creds | args:export | args:import | args:drop)
      [[ $3 == 1 && -f $DB_DATABASES_FILE ]] && cut -f1 -- "$DB_DATABASES_FILE" | sort -u
      [[ $3 == 1 && $2 == shell ]] && db_server_ids | grep '^redis-' || true
      ;;
    flags:create) printf '%s\n' --engine --version --server ;;
    flags:add) printf '%s\n' --version --any-port ;;
    flags:stop) printf '%s\n' --force ;;
    flags:list) printf '%s\n' --databases ;;
    flags:root) printf '%s\n' --show-key ;;
    flags:creds | flags:shell | flags:export | flags:import) printf '%s\n' --server ;;
  esac
  return 0
}

help_db() {
  cat <<'HELP'
Usage: devctl db [list] [--databases]            servers (or databases) and their state
       devctl db engines                          available engines and versions
       devctl db add ENGINE [--version V]          register a shared server (port fixed forever)
       devctl db create NAME --engine ENGINE [--version V]
                                                  database + its own user (new password)
       devctl db creds NAME | --server SERVER      connection details for TablePlus
       devctl db shell NAME                       client as the database's user (redis: SERVER)
       devctl db root SERVER [--show-key]          superuser shell (separate on purpose)
       devctl db start|stop SERVER [--force]       stop refuses while sites use the server
       devctl db export NAME [FILE.gz]             dump through the container, gzip
       devctl db import NAME FILE[.gz]             asks you to type NAME if not empty
       devctl db drop NAME                        delete a database no site uses (type NAME)
       devctl db legacy-remove                    remove the old ~/Desktop/projects/databases setup

Servers listen on 127.0.0.1 only. Data: ~/.local/share/devctl/data/SERVER (copy-on-write off).
Passwords: ~/.local/share/devctl/secrets (0600). Engines: mysql, mariadb, postgres (pgvector),
mongodb, qdrant, redis (cache only), sqlite (file in the project).
HELP
}
