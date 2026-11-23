# shellcheck shell=bash
# dbservers.sh — database servers and databases (ADR-0007, ADR-0008).
#
# Registry (machine-written, under ~/.local/share/devctl/registry/):
#   servers.tsv    ID  ENGINE  MAJOR  IMAGE  PORT  CREATED
#   ports.tsv      PORT  OWNER  CREATED          (never shrinks: a port is never reused)
#   databases.tsv  NAME  SERVER  USER  CREATED
# Secrets (0600): secrets/servers/ID.env (root), secrets/databases/SERVER/NAME.env (user).
# Data: data/ID inside the No-CoW Btrfs subvolume made by `devctl init`.

# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

[[ -n ${__DEVCTL_DBSERVERS_SH:-} ]] && return 0
__DEVCTL_DBSERVERS_SH=1

adapter_load engine

DB_ENGINES_DIR="$DEVCTL_ROOT/templates/engines"
DB_REGISTRY_DIR="$DEVCTL_DATA_DIR/registry"
DB_SERVERS_FILE="$DB_REGISTRY_DIR/servers.tsv"
DB_PORTS_FILE="$DB_REGISTRY_DIR/ports.tsv"
DB_DATABASES_FILE="$DB_REGISTRY_DIR/databases.tsv"
DB_STACKS_DIR="$DEVCTL_DATA_DIR/stacks"
DB_DATA_DIR="$DEVCTL_DATA_DIR/data"
DB_REFCOUNT_DIR="$DEVCTL_RUN_DIR/refcount"
readonly DB_NETWORK=devctl

# ---- engines ----------------------------------------------------------------------------

# dbe_engines [CATEGORY] — engine templates; CATEGORY database (default) or service.
dbe_engines() {
  local dir want=${1:-database} category
  for dir in "$DB_ENGINES_DIR"/*/; do
    dir=${dir%/}
    [[ -f $dir/engine.conf ]] || continue
    category=$(sed -n 's/^category *= *//p' "$dir/engine.conf")
    [[ ${category:-database} == "$want" ]] && printf '%s\n' "${dir##*/}"
  done
  return 0
}

# dbe_load ENGINE ARRAY — read templates/engines/ENGINE/engine.conf into ARRAY.
dbe_load() {
  local engine=$1
  is_identifier "$engine" && [[ -f $DB_ENGINES_DIR/$engine/engine.conf ]] ||
    die "$EX_NOTFOUND" "unknown database engine '$engine' (see: devctl db engines)"
  kv_read "$DB_ENGINES_DIR/$engine/engine.conf" "$2"
  kv_require "$2" "$engine/engine.conf" name kind majors default_major
}

declare -gA __DBE_DRIVERS=()

dbe__driver_load() {
  [[ -n ${__DBE_DRIVERS[$1]:-} ]] && return 0
  # shellcheck source=/dev/null  # one driver per engine folder
  source "$DB_ENGINES_DIR/$1/driver.sh"
  __DBE_DRIVERS[$1]=1
}

# dbe_supports ENGINE OPERATION — the engine's driver implements OPERATION.
dbe_supports() {
  dbe__driver_load "$1"
  declare -F -- "${1}_$2" >/dev/null
}

# dbe_call ENGINE OPERATION ARGS... — run ENGINE's driver function ENGINE_OPERATION.
dbe_call() {
  local engine=$1 op=$2
  shift 2
  dbe_supports "$engine" "$op" || die "$EX_PRECONDITION" "$engine does not support '$op'"
  "${engine}_${op}" "$@"
}

# ---- registry ---------------------------------------------------------------------------

db__registry_init() {
  ensure_private_dir "$DB_REGISTRY_DIR"
  local f
  for f in "$DB_SERVERS_FILE" "$DB_PORTS_FILE" "$DB_DATABASES_FILE"; do
    [[ -e $f ]] || : >"$f"
  done
}

# db__append FILE FIELD... — append one TSV row atomically (caller holds the registry lock).
db__append() {
  local file=$1 tmp line
  shift
  local IFS=$'\t'
  line="$*"
  tmp=$(mktemp "${file%/*}/.reg.XXXXXX")
  cat -- "$file" >"$tmp"
  printf '%s\n' "$line" >>"$tmp"
  mv -f -- "$tmp" "$file"
}

db_server_id() { # ENGINE MAJOR → mysql-8-4
  printf '%s-%s\n' "$1" "${2//./-}"
}

# db_server_get ID ARRAY — fill ARRAY (id engine major image port created); 1 if unknown.
db_server_get() {
  local -n __srv=$2
  local id engine major image port created
  [[ -f $DB_SERVERS_FILE ]] || return 1
  while IFS=$'\t' read -r id engine major image port created; do
    if [[ $id == "$1" ]]; then
      __srv=([id]=$id [engine]=$engine [major]=$major [image]=$image [port]=$port [created]=$created)
      return 0
    fi
  done <"$DB_SERVERS_FILE"
  return 1
}

db_server_ids() {
  [[ -f $DB_SERVERS_FILE ]] && cut -f1 -- "$DB_SERVERS_FILE"
  return 0
}

# Containers and compose projects are named <engine.name_prefix>-<id> (tests use their own prefix).
# db_server_port ID [NAME] — the server's main port, or its extra port NAME (e.g. ui).
db_server_port() {
  local owner=$1${2:+/$2}
  [[ -f $DB_PORTS_FILE ]] || return 0
  awk -F'\t' -v o="$owner" '$2 == o {print $1; exit}' "$DB_PORTS_FILE"
}

db_server_container() { printf '%s-%s\n' "$(config_get engine.name_prefix)" "$1"; }
db_server_stack() { printf '%s/%s/compose.yaml\n' "$DB_STACKS_DIR" "$1"; }
db_server_secrets() { printf '%s/servers/%s.env\n' "$DEVCTL_SECRETS_DIR" "$1"; }

# db_port_free PORT — not registered to anyone and nothing listens on it.
db_port_free() {
  local port=$1
  [[ -f $DB_PORTS_FILE ]] && cut -f1 -- "$DB_PORTS_FILE" | grep -qx -- "$port" && return 1
  ! ss -ltnH "sport = :$port" 2>/dev/null | grep -q .
}

# db__port_allocate START OWNER — first free port from START; recorded forever.
db__port_allocate() {
  local port=$1
  while ! db_port_free "$port"; do
    ((port++))
    ((port <= 65535)) || die "$EX_CONFLICT" "no free port found from $1"
  done
  db__append "$DB_PORTS_FILE" "$port" "$2" "$(date +%F)"
  printf '%s\n' "$port"
}

# db_server_add ENGINE [MAJOR] [--any-port] — register a shared server (does not start it).
# Prints the server id. Idempotent.
db_server_add() {
  local engine=$1 major=${2:-} any_port=${3:-} id port image
  # shellcheck disable=SC2034  # prior is filled through a nameref
  local -A conf=() prior=()
  dbe_load "$engine" conf
  [[ ${conf[kind]} == server ]] || die "$EX_USAGE" "${conf[name]} has no server (it is a file inside the project)"
  major=${major:-${conf[default_major]}}
  # shellcheck disable=SC2086  # majors is a space-separated list
  is_in_list "$major" ${conf[majors]} || die "$EX_VALIDATION" "${conf[name]} version '$major' is not available (choose: ${conf[majors]})"
  id=$(db_server_id "$engine" "$major")

  if db_server_get "$id" prior; then
    printf '%s\n' "$id"
    return 0
  fi
  if ((DEVCTL_DRY_RUN)); then
    # stdout carries the id (callers capture it), so the plan line goes to stderr.
    ui_plan "register server $id (${conf[name]} $major), port from ${conf[default_host_port]}, data $DB_DATA_DIR/$id" >&2
    printf '%s\n' "$id"
    return 0
  fi

  lock_acquire registry
  db__registry_init
  local p
  for p in "${conf[default_host_port]}" ${conf[extra_ports]:+$(printf '%s\n' ${conf[extra_ports]} | cut -d: -f2)}; do
    if [[ $any_port != --any-port ]] && ! db_port_free "$p"; then
      lock_release registry
      die "$EX_CONFLICT" "port $p (the usual ${conf[name]} port) is in use. Ports are assigned once and never change, so free it first (old containers: devctl db legacy-remove), or accept other ports with --any-port"
    fi
  done
  port=$(db__port_allocate "${conf[default_host_port]}" "$id")
  image=${conf[image]//\{major\}/$major}
  # extra_ports = name:default ... (e.g. ui:8025) → recorded as owner "<id>/<name>"
  local extra
  for extra in ${conf[extra_ports]:-}; do
    db__port_allocate "${extra#*:}" "$id/${extra%%:*}" >/dev/null
  done

  # root_secret = KEY... (generated) · root_user / static_env = KEY=value ... (fixed)
  local -a entries=()
  local key
  for key in ${conf[root_secret]:-}; do entries+=("$key=$(secret_generate)"); done
  for key in ${conf[root_user]:-} ${conf[static_env]:-}; do entries+=("$key"); done
  if ((${#entries[@]})); then
    secret_write "$(db_server_secrets "$id")" "${entries[@]}"
  fi
  if bool_true "${conf[persistent]:-yes}"; then
    ensure_private_dir "$DB_DATA_DIR/$id" # inherits No-CoW from the data subvolume
    # 0711: the database's own user inside the container may pass through (e.g. postgres);
    # nobody can list it, and data/ above is 0700 for other accounts on this laptop.
    chmod 711 -- "$DB_DATA_DIR/$id"
  fi
  db__append "$DB_SERVERS_FILE" "$id" "$engine" "$major" "$image" "$port" "$(date +%F)"
  lock_release registry
  log_info "registered server $id on port $port"
  printf '%s\n' "$id"
}

# db_server_render ID — write the server's compose file from its engine template.
db_server_render() {
  local -A srv=()
  db_server_get "$1" srv || die "$EX_NOTFOUND" "unknown server '$1'"
  local tmpl="$DB_ENGINES_DIR/${srv[engine]}/compose.yaml.tmpl" file content
  file=$(db_server_stack "$1")
  content=$(<"$tmpl")
  content=${content//\{\{NAME\}\}/$(db_server_container "${srv[id]}")}
  content=${content//\{\{ID\}\}/${srv[id]}}
  content=${content//\{\{MAJOR\}\}/${srv[major]}}
  content=${content//\{\{UID\}\}/$(id -u)}
  content=${content//\{\{GID\}\}/$(id -g)}
  local owner port name
  [[ -f $DB_PORTS_FILE ]] && while IFS=$'\t' read -r port owner _; do
    [[ $owner == "${srv[id]}/"* ]] || continue
    name=${owner#*/}
    content=${content//\{\{PORT_${name^^}\}\}/$port}
  done <"$DB_PORTS_FILE"
  content=${content//\{\{IMAGE\}\}/${srv[image]}}
  content=${content//\{\{PORT\}\}/${srv[port]}}
  content=${content//\{\{DATA\}\}/$DB_DATA_DIR/${srv[id]}}
  content=${content//\{\{SECRETS\}\}/$(db_server_secrets "${srv[id]}")}
  [[ $content != *'{{'* ]] || die "$EX_FAIL" "unfilled placeholder in $tmpl (bug)"
  ensure_private_dir "${file%/*}"
  printf '%s\n' "$content" >"$file"
  printf '%s\n' "$file"
}

db_server_state() { # ID → running | stopped | <other docker state>
  ce_daemon_running || { printf 'stopped\n'; return 0; }
  local state
  state=$(ce_status "$(db_server_container "$1")")
  [[ $state == missing || $state == exited ]] && state=stopped
  printf '%s\n' "$state"
}

db_server_start() {
  local id=$1 file
  local -A srv=() conf=()
  db_server_get "$id" srv || die "$EX_NOTFOUND" "unknown server '$id' (see: devctl db list)"
  dbe_load "${srv[engine]}" conf
  ce_ensure_running
  [[ $(db_server_state "$id") == running ]] && return 0
  bool_true "${conf[heavy]:-no}" && guard_memory "${conf[name]} ${srv[major]}"
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "start server $id (${srv[image]}) on 127.0.0.1:${srv[port]}"
    return 0
  fi
  ce_network_ensure "$DB_NETWORK"
  file=$(db_server_render "$id")
  ce_up "$(db_server_container "$id")" "$file" || die "$EX_EXTERNAL" "server $id did not start; see: devctl logs --db $id"
}

# Removes the server's containers whatever their state (running, exited, unhealthy…);
# data stays in the data folder.
db_server_stop() {
  local id=$1
  ce_daemon_running || return 0
  [[ $(ce_status "$(db_server_container "$id")") == missing ]] && return 0
  ce_down "$(db_server_container "$id")" "$(db_server_render "$id")"
}

# ---- users of a server (which sites need it running) -------------------------------------
# One marker file per user: run/refcount/<server>/<holder>. Acquiring twice or releasing
# twice changes nothing, so the count can never drift (a counter could, e.g. after a
# failed start). Older numeric counter files are ignored.

db__holders_dir() { printf '%s/%s\n' "$DB_REFCOUNT_DIR" "$1"; }

db_refcount() {
  local dir
  dir=$(db__holders_dir "$1")
  [[ -d $dir ]] || { printf '0\n'; return 0; }
  find "$dir" -mindepth 1 -maxdepth 1 -type f | wc -l
}

db_server_holders() {
  local dir f
  dir=$(db__holders_dir "$1")
  for f in "$dir"/*; do [[ -f $f ]] && printf '%s\n' "${f##*/}"; done
  return 0
}

db__holders_clear() {
  local dir
  dir=$(db__holders_dir "$1")
  [[ -f $dir ]] && rm -f -- "$dir" # old numeric counter
  [[ -d $dir ]] && find "$dir" -mindepth 1 -maxdepth 1 -type f -delete
  return 0
}

# db_server_acquire SERVER HOLDER — start the server if needed; HOLDER (a site) uses it.
db_server_acquire() {
  local dir
  db_server_start "$1"
  ((DEVCTL_DRY_RUN)) && return 0
  dir=$(db__holders_dir "$1")
  [[ -f $dir ]] && rm -f -- "$dir"
  ensure_private_dir "$dir"
  : >"$dir/$2"
}

# db_server_release SERVER HOLDER — HOLDER no longer needs it; stop when nobody does.
db_server_release() {
  ((DEVCTL_DRY_RUN)) && return 0
  rm -f -- "$(db__holders_dir "$1")/$2"
  (($(db_refcount "$1") == 0)) && db_server_stop "$1"
  return 0
}

# ---- databases --------------------------------------------------------------------------

db_name_valid() { [[ $1 =~ ^[a-z][a-z0-9_]{0,31}$ ]]; }

db_database_secrets() { printf '%s/databases/%s/%s.env\n' "$DEVCTL_SECRETS_DIR" "$1" "$2"; }

# db_database_servers NAME — servers that have a database NAME.
db_database_servers() {
  [[ -f $DB_DATABASES_FILE ]] || return 0
  awk -F'\t' -v n="$1" '$1 == n {print $2}' "$DB_DATABASES_FILE"
}

# db_database_resolve NAME [SERVER] — print the one server holding NAME, or die.
db_database_resolve() {
  local name=$1 server=${2:-}
  local -a found=()
  mapfile -t found < <(db_database_servers "$name")
  if [[ -n $server ]]; then
    is_in_list "$server" "${found[@]}" || die "$EX_NOTFOUND" "no database '$name' on server '$server'"
    printf '%s\n' "$server"
  elif ((${#found[@]} == 1)); then
    printf '%s\n' "${found[0]}"
  elif ((${#found[@]} == 0)); then
    die "$EX_NOTFOUND" "no database named '$name' (see: devctl db list --databases)"
  else
    die "$EX_USAGE" "'$name' exists on several servers (${found[*]}); add --server"
  fi
}

# db_database_create SERVER NAME — database + least-privilege user NAME with a new password.
db_database_create() {
  local server=$1 name=$2 pass container
  local -A srv=() conf=()
  db_name_valid "$name" || die "$EX_VALIDATION" "invalid database name '$name': lowercase letters, digits and _, starting with a letter, max 32"
  db_server_get "$server" srv || die "$EX_NOTFOUND" "unknown server '$server'"
  dbe_load "${srv[engine]}" conf
  container=$(db_server_container "$server")
  if [[ -n $(db_database_servers "$name" | grep -x -- "$server" || true) ]]; then
    die "$EX_CONFLICT" "database '$name' already exists on $server"
  fi
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "create database '$name' and user '$name' (new password) on $server"
    return 0
  fi
  pass=$(secret_generate)
  dbe_call "${srv[engine]}" create "$container" "$name" "$name" "$pass" >/dev/null ||
    die "$EX_EXTERNAL" "could not create database '$name' on $server"
  secret_write "$(db_database_secrets "$server" "$name")" "DB_DATABASE=$name" "DB_USERNAME=$name" "DB_PASSWORD=$pass"
  lock_acquire registry
  db__registry_init
  db__append "$DB_DATABASES_FILE" "$name" "$server" "$name" "$(date +%F)"
  lock_release registry
}

# db_database_sites SERVER NAME — the sites whose database is NAME on SERVER.
db_database_sites() {
  local f
  for f in "$DEVCTL_DATA_DIR"/registry/sites/*.conf; do
    [[ -f $f ]] || continue
    awk -v srv="$1" -v db="$2" -F' = ' '
      $1 == "name" { n = $2 } $1 == "db_server" { s = $2 } $1 == "db_name" { d = $2 }
      END { if (s == srv && d == db) print n }' "$f"
  done
}

# db_database_drop SERVER NAME — delete the database, its user and its saved password.
# Callers confirm first (typed name) and make sure no site still uses it.
db_database_drop() {
  local server=$1 name=$2 container was user
  local -A srv=()
  db_name_valid "$name" || die "$EX_VALIDATION" "invalid database name '$name'"
  db_server_get "$server" srv || die "$EX_NOTFOUND" "unknown server '$server'"
  db_database_servers "$name" | grep -qx -- "$server" || die "$EX_NOTFOUND" "no database '$name' on $server"
  dbe_supports "${srv[engine]}" drop || die "$EX_PRECONDITION" "${srv[engine]} databases cannot be deleted by devctl"
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "delete database '$name' and its user on $server (all its tables and data), forget its password"
    return 0
  fi
  local secrets
  secrets=$(db_database_secrets "$server" "$name")
  user=$name
  [[ -r $secrets ]] && user=$(secret_get "$secrets" DB_USERNAME)
  db_name_valid "$user" || user=$name
  was=$(db_server_state "$server")
  db_server_start "$server"
  container=$(db_server_container "$server")
  ui_step "Deleting database $name on $server"
  dbe_call "${srv[engine]}" drop "$container" "$name" "$user" >/dev/null ||
    die "$EX_EXTERNAL" "could not delete database '$name' on $server"
  rm -f -- "$(db_database_secrets "$server" "$name")"
  lock_acquire registry
  awk -F'\t' -v n="$name" -v s="$server" '!($1 == n && $2 == s)' "$DB_DATABASES_FILE" >"$DB_DATABASES_FILE.tmp" &&
    mv -f -- "$DB_DATABASES_FILE.tmp" "$DB_DATABASES_FILE"
  lock_release registry
  # Leave the server as it was found (stopped unless a site needs it).
  [[ $was != running ]] && (($(db_refcount "$server") == 0)) && db_server_stop "$server"
  return 0
}
