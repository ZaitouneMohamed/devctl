# shellcheck shell=bash
# sites.sh — projects ("sites"): create from a template or clone, serve, start/stop, delete.
#
# Registry: ~/.local/share/devctl/registry/sites/<name>.conf (key = value).
# A site = a folder in <projects.root>/<category>/<name>, the name <name>.<suffix>,
# a Caddy site file, SELinux labels + read-only ACLs for Caddy, optionally a database.

# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

[[ -n ${__DEVCTL_SITES_SH:-} ]] && return 0
__DEVCTL_SITES_SH=1

# shellcheck source=lib/services/dbservers.sh
source "$DEVCTL_ROOT/lib/services/dbservers.sh"
# shellcheck source=lib/services/php.sh
source "$DEVCTL_ROOT/lib/services/php.sh"
adapter_load web
adapter_load dns

SITES_REGISTRY="$DEVCTL_DATA_DIR/registry/sites"
SITES_TEMPLATES="$DEVCTL_ROOT/templates/projects"
# site_php NAME — the site's PHP version (older sites: Fedora's).
site_php() {
  local -A s=()
  site_load "$1" s
  printf '%s\n' "${s[php_version]:-$(php_system_version)}"
}
readonly SITES_VITE_FIRST=44300 SITES_VITE_LAST=44399 SITES_VITE_OFFSET=10000
readonly SITES_FNM="$HOME/.local/bin/fnm"

# ---- registry -----------------------------------------------------------------------------

site_names() {
  local f
  for f in "$SITES_REGISTRY"/*.conf; do
    [[ -f $f ]] || continue
    f=${f##*/}
    printf '%s\n' "${f%.conf}"
  done
}

site_exists() { [[ -f $SITES_REGISTRY/$1.conf ]]; }

site_load() { # NAME ARRAY
  site_exists "$1" || die "$EX_NOTFOUND" "no site named '$1' (see: devctl site list)"
  kv_read "$SITES_REGISTRY/$1.conf" "$2"
}

site__save() { # NAME KEY=VALUE... (whole file rewritten)
  local name=$1 tmp pair
  shift
  ensure_private_dir "$SITES_REGISTRY"
  tmp=$(mktemp "$SITES_REGISTRY/.site.XXXXXX")
  printf '# devctl site registry entry (machine-written)\n' >"$tmp"
  for pair; do
    [[ $pair =~ ^[a-z_]+=[^$'\n']*$ ]] || { rm -f -- "$tmp"; die "$EX_FAIL" "bad registry entry (bug)"; }
    printf '%s = %s\n' "${pair%%=*}" "${pair#*=}" >>"$tmp"
  done
  mv -f -- "$tmp" "$SITES_REGISTRY/$name.conf"
}

site__set() { # NAME KEY VALUE — update one key
  local -A s=()
  site_load "$1" s
  s[$2]=$3
  local -a pairs=()
  local k
  for k in "${!s[@]}"; do pairs+=("$k=${s[$k]}"); done
  site__save "$1" "${pairs[@]}"
}

site_domain() { printf '%s.%s\n' "$1" "$(config_get domain.suffix)"; }
site_path() { printf '%s/%s/%s\n' "$(config_get_path projects.root)" "$2" "$1"; }
site_db_name() { printf '%s\n' "${1//-/_}"; }

# site_validate_new NAME CATEGORY — name rules, uniqueness, category.
site_validate_new() {
  local name=$1 category=$2 word
  require_valid domain_label "$name" "site name"
  for word in $(config_get domain.reserved); do
    [[ $name == "$word" ]] && die "$EX_VALIDATION" "'$name' is reserved"
  done
  ((${#name} <= 32)) || die "$EX_VALIDATION" "site names are limited to 32 characters (database user names)"
  # shellcheck disable=SC2046  # categories are a space-separated list of identifiers
  is_in_list "$category" $(config_get projects.categories) ||
    die "$EX_VALIDATION" "unknown category '$category' (choose: $(config_get projects.categories))"
  site_exists "$name" && die "$EX_CONFLICT" "a site named '$name' already exists"
  [[ $(dns_names | grep -cx -- "$(site_domain "$name")") == 0 ]] || die "$EX_CONFLICT" "$(site_domain "$name") is already in use"
  [[ ! -e $(site_path "$name" "$category") ]] || die "$EX_CONFLICT" "$(site_path "$name" "$category") already exists"
}

# ---- pieces ---------------------------------------------------------------------------------

# site__vite_ports NAME — "PUBLIC INTERNAL"; the public port is recorded forever.
site__vite_port_allocate() {
  local port
  lock_acquire registry
  db__registry_init
  for ((port = SITES_VITE_FIRST; port <= SITES_VITE_LAST; port++)); do
    if db_port_free "$port" && db_port_free $((port + SITES_VITE_OFFSET)); then
      db__append "$DB_PORTS_FILE" "$port" "vite-$1" "$(date +%F)"
      lock_release registry
      printf '%s\n' "$port"
      return 0
    fi
  done
  lock_release registry
  die "$EX_CONFLICT" "no free Vite port left in $SITES_VITE_FIRST-$SITES_VITE_LAST"
}

# env_set FILE KEY VALUE — set KEY in a .env file: replaces "KEY=…" or "# KEY=…", else appends.
env_set() {
  local file=$1 key=$2 value=$3 tmp
  [[ $key =~ ^[A-Z][A-Z0-9_]*$ && $value =~ ^[A-Za-z0-9._:/@+-]*$ ]] || die "$EX_FAIL" "bad .env entry $key (bug)"
  tmp=$(mktemp "${file%/*}/.env.XXXXXX")
  awk -v k="$key" -v v="$value" '
    !done && ($0 ~ "^" k "=" || $0 ~ "^# *" k "=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$file" >"$tmp"
  chmod 600 -- "$tmp"
  mv -f -- "$tmp" "$file"
}

# Read-only access for Caddy (user "caddy"): traverse the parents, read the public folder.
# Caddy never gets access to .env, vendor/ or sources (PHP-FPM runs as you).
site__acl_grant() { # PATH SERVED_DIR
  local path=$1 served=$2 dir
  dir=$path
  while [[ $dir == "$HOME"/* ]]; do
    run_change --desc "Let Caddy pass through" -- setfacl -m u:caddy:x -- "$dir" || return
    dir=${dir%/*}
  done
  run_change --desc "Let Caddy pass through" -- setfacl -m u:caddy:x -- "$HOME" || return
  [[ -d $served ]] || return 0
  run_change --desc "Let Caddy read $served" -- setfacl -R -m u:caddy:rX -m d:u:caddy:rX -- "$served"
}

site__acl_revoke() { # PATH — remove Caddy's entries inside the project (parents keep traverse)
  [[ -d $1 ]] || return 0
  run_change --desc "Remove Caddy's access" -- setfacl -R -x u:caddy -x d:u:caddy -- "$1"
}

site__git_extras() { # PATH — notify-only hooks + keep devctl's Vite file out of git
  local path=$1 hook
  [[ -d $path/.git ]] || return 0
  for hook in post-merge post-checkout; do
    if [[ -e $path/.git/hooks/$hook ]] && ! grep -qs 'Added by devctl' "$path/.git/hooks/$hook"; then
      ui_note "$hook hook already exists in $path; not replaced"
      continue
    fi
    run_change --desc "Install git hook $hook (notification only)" -- \
      install -m 0755 -T -- "$DEVCTL_ROOT/templates/git-hooks/devctl-notify" "$path/.git/hooks/$hook"
  done
  if ! grep -qsx 'devctl.vite.config.ts' "$path/.git/info/exclude"; then
    ((DEVCTL_DRY_RUN)) || printf 'devctl.vite.config.ts\n' >>"$path/.git/info/exclude"
  fi
}

# fnm exec with the project's Node version (.nvmrc / .node-version), else the default.
site__node() { # PATH CMD...
  local path=$1 v
  shift
  [[ -x $SITES_FNM ]] || die "$EX_PRECONDITION" "Node is not set up: devctl runtime setup node"
  v=$(config_get runtime.node_default)
  if [[ -f $path/.nvmrc ]]; then v=$(tr -d ' \r\n' <"$path/.nvmrc")
  elif [[ -f $path/.node-version ]]; then v=$(tr -d ' \r\nv' <"$path/.node-version")
  fi
  [[ $v =~ ^v?[0-9][0-9.]*$|^lts/[a-z*]+$ ]] || die "$EX_VALIDATION" "unsupported Node version '$v' in $path"
  "$SITES_FNM" ls 2>/dev/null | grep -q " v${v#v}" || run_change --desc "Install Node $v" -- "$SITES_FNM" install "$v" || return
  (cd -- "$path" && "$SITES_FNM" exec --using="$v" -- "$@")
}

# Java: the project's .java-version (else the default) → Fedora's JDK folder.
site__java_version() {
  local v
  v=$(config_get runtime.java_default)
  [[ -f $1/.java-version ]] && v=$(tr -d ' \r\n' <"$1/.java-version")
  [[ $v =~ ^[0-9]{1,3}$ ]] || die "$EX_VALIDATION" "unsupported Java version '$v' in $1/.java-version"
  printf '%s\n' "$v"
}
site__java_home() { printf '/usr/lib/jvm/java-%s-openjdk\n' "$(site__java_version "$1")"; }

site__java() { # PATH CMD... — run with the project's JDK first in PATH
  local home
  home=$(site__java_home "$1")
  [[ -x $home/bin/javac ]] || die "$EX_PRECONDITION" "JDK $(site__java_version "$1") not installed ($home); devctl runtime setup java"
  shift
  JAVA_HOME=$home PATH="$home/bin:$PATH" "$@"
}

# site__serve NAME — web config, local name, SELinux labels, ACLs; apply; make sure the
# web server and PHP-FPM run. Everything system-level goes through the helper (asked).
site__serve() {
  local name=$1 kind served php_ver=""
  local -A s=()
  site_load "$name" s
  kind=${s[kind]}
  [[ $kind == none ]] && return 0 # no website (e.g. plain Java)
  if [[ $kind == proxy ]]; then
    # Caddy forwards to the app's local port; it never reads the project's files.
    web_render proxy "$name" "${s[domain]}" "${s[tls]}" - "${s[app_port]}" -
    dns_add "${s[domain]}"
    dns_apply
    web_needs_apply && web_apply
    web_start
    return 0
  fi
  case $kind in
    laravel) served="${s[path]}/public"
      php_ver=${s[php_version]:-$(php_system_version)}
      php_fpm_ready "$php_ver" || die "$EX_PRECONDITION" "PHP $php_ver has no devctl pool yet: devctl runtime php add $php_ver"
      web_render php "$name" "${s[domain]}" "${s[tls]}" "${s[path]}" - "$(php_fpm_socket "$php_ver")" "${s[vite_port]:--}" ;;
    static) served="${s[path]}"
      web_render static "$name" "${s[domain]}" "${s[tls]}" "${s[path]}" - - "-" ;;
    *) die "$EX_FAIL" "unknown site kind '$kind'" ;;
  esac
  site__acl_grant "${s[path]}" "$served"
  priv_run --desc "SELinux labels for ${s[path]}" project-label "${s[path]}" || die "$EX_EXTERNAL" "could not label the project"
  dns_add "${s[domain]}"
  dns_apply
  web_needs_apply && web_apply
  if [[ $kind == laravel ]] && ! systemctl is-active --quiet "$(php_fpm_unit "$php_ver")"; then
    local -a ver_arg=()
    [[ -n $(php_helper_arg "$php_ver") ]] && ver_arg=("$php_ver")
    priv_run --desc "Start PHP-FPM $php_ver" php-fpm-start "${ver_arg[@]}"
  fi
  web_start
}

# ---- create ----------------------------------------------------------------------------

readonly SITES_APP_FIRST=8100 SITES_APP_LAST=8199

# site__template_load TEMPLATE ARRAY — template.conf into ARRAY and its create.sh functions.
site__template_load() {
  local dir="$SITES_TEMPLATES/$1"
  is_identifier "$1" && [[ -f $dir/template.conf && -f $dir/create.sh ]] || die "$EX_NOTFOUND" "unknown template '$1' (see: devctl site templates)"
  kv_read "$dir/template.conf" "$2"
  unset -f tpl_create tpl_configure tpl_dev laravel_after_env
  # shellcheck source=/dev/null  # one create.sh per template folder
  source "$dir/create.sh"
}

# site__app_port_allocate NAME — local port for an app Caddy proxies to (recorded forever).
site__app_port_allocate() {
  local port
  lock_acquire registry
  db__registry_init
  for ((port = SITES_APP_FIRST; port <= SITES_APP_LAST; port++)); do
    if db_port_free "$port"; then
      db__append "$DB_PORTS_FILE" "$port" "app-$1" "$(date +%F)"
      lock_release registry
      printf '%s\n' "$port"
      return 0
    fi
  done
  lock_release registry
  die "$EX_CONFLICT" "no free app port left in $SITES_APP_FIRST-$SITES_APP_LAST"
}

# site__existing_db DB [SERVER] — "SERVER ENGINE" for an existing devctl database (dies if
# unknown or ambiguous). Used to connect a site to a database another site already uses.
site__existing_db() {
  local server
  local -A srv=()
  db_name_valid "$1" || die "$EX_VALIDATION" "invalid database name '$1'"
  server=$(db_database_resolve "$1" "${2:-}")
  db_server_get "$server" srv
  printf '%s %s\n' "$server" "${srv[engine]}"
}

site_create() { # NAME CATEGORY TEMPLATE ENGINE [EXISTING_DB]   (ENGINE: an engine, sqlite, none)
  local name=$1 category=$2 template=$3 engine=${4:-none} existing=${5:-} path domain="" server="" db="" kind
  local vite="" app="" port="" user="" pass=""
  local -A tpl=() srv=()
  site__template_load "$template" tpl
  kind=${tpl[kind]}
  path=$(site_path "$name" "$category")
  [[ $kind == none ]] || domain=$(site_domain "$name")

  if [[ ! -d ${path%/*} ]]; then
    run_change --desc "Create the category folder" -- mkdir -p -- "${path%/*}" || return
  fi
  ui_step "Creating the project (${tpl[name]})"
  tpl_create "$path" "$name" "$engine"
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "database: $engine; configure; ports; web/SELinux/ACL/hosts as needed; register $name"
    return 0
  fi

  if [[ -n $existing ]]; then
    # Share a database another site already uses: same database, same user and password.
    local existing_info
    existing_info=$(site__existing_db "$existing")
    read -r server engine <<<"$existing_info"
    db=$existing
    db_server_get "$server" srv
    db_server_start "$server"
    port=${srv[port]}
    user=$(secret_get "$(db_database_secrets "$server" "$db")" DB_USERNAME)
    pass=$(secret_get "$(db_database_secrets "$server" "$db")" DB_PASSWORD)
  elif [[ $engine != none && $engine != sqlite ]]; then
    db=$(site_db_name "$name")
    server=$(db_server_add "$engine")
    db_server_get "$server" srv
    db_server_start "$server"
    db_database_create "$server" "$db"
    port=${srv[port]}
    user=$(secret_get "$(db_database_secrets "$server" "$db")" DB_USERNAME)
    pass=$(secret_get "$(db_database_secrets "$server" "$db")" DB_PASSWORD)
  fi
  if declare -F tpl_configure >/dev/null; then
    # An existing database keeps its tables: the template does not run its migrations
    # (Laravel) or let Hibernate change the schema (Spring Boot).
    SITE_EXISTING_DB=${existing:+1} tpl_configure "$path" "$name" "$engine" "$port" "$db" "$user" "$pass"
  fi
  [[ -n $existing ]] && ui_note "connected to the existing database $existing as is; to run this project's migrations too: devctl site db $name --use $existing --fill migrate"

  case $kind in
    laravel)
      if bool_true "${tpl[vite]:-yes}"; then
        vite=$(site__vite_port_allocate "$name")
        install -m 0644 -T -- "$DEVCTL_ROOT/templates/vite/devctl.vite.config.ts" "$path/devctl.vite.config.ts"
      fi
      ;;
    proxy) app=$(site__app_port_allocate "$name") ;;
  esac
  site__save "$name" "name=$name" "category=$category" "path=$path" "domain=$domain" "kind=$kind" \
    "template=$template" "tls=on" "db_engine=${engine/none/}" "db_server=$server" "db_name=$db" \
    "vite_port=$vite" "app_port=$app" "origin=template" "php_version=$([[ $kind == laravel ]] && php_system_version)" "created=$(date +%F)"
  site__git_extras "$path"
  site__serve "$name"
}

# ---- clone --------------------------------------------------------------------------------

# site_clone URL NAME CATEGORY — clone, install dependencies once (asked), serve.
# .env, database and migrations stay yours (requirements §3.1).
# site__detect PATH — "KIND TEMPLATE" for a cloned project, or nothing if unknown.
site__detect() {
  local p=$1
  if [[ -f $p/composer.json ]] && grep -q '"laravel/framework"' "$p/composer.json"; then
    printf 'laravel -\n'
  elif grep -qs 'spring-boot' "$p/pom.xml" || grep -qs 'org.springframework.boot' "$p/build.gradle" "$p/build.gradle.kts"; then
    printf 'proxy spring-boot\n'
  elif [[ ! -f $p/pom.xml && ! -f $p/build.gradle && ! -f $p/build.gradle.kts && -d $p/src ]] &&
    [[ -n $(find "$p/src" -name '*.java' -print -quit) ]]; then
    printf 'none java\n'
  elif [[ -f $p/index.html ]]; then
    printf 'static -\n'
  fi
}

# site__repo_url SOURCE — accept OWNER/REPO (GitHub) or an https:// / git@ URL.
site__repo_url() {
  if [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]]; then
    printf 'https://github.com/%s.git\n' "${1%.git}"
  elif [[ $1 =~ ^(https://|git@)[A-Za-z0-9._@:/~+-]+$ ]]; then
    printf '%s\n' "$1"
  else
    die "$EX_VALIDATION" "unsupported repository: use OWNER/REPO or an https:// or git@ URL"
  fi
}

site_clone() {
  local source=$1 name=$2 category=$3 path domain kind template policy="shared" url
  path=$(site_path "$name" "$category")
  domain=$(site_domain "$name")
  url=$(site__repo_url "$source")
  if [[ ! -d ${path%/*} ]]; then
    run_change --desc "Create the category folder" -- mkdir -p -- "${path%/*}" || return
  fi
  # gh (when signed in) clones private repositories with your GitHub sign-in.
  if [[ $url == https://github.com/* ]] && command -v gh >/dev/null && gh auth status --hostname github.com >/dev/null 2>&1; then
    run_change --desc "Clone (gh)" -- gh repo clone "$url" "$path" || die "$EX_EXTERNAL" "cloning failed (is the repository name right, and do you have access?)"
  else
    run_change --desc "Clone" -- git clone -- "$url" "$path" ||
      die "$EX_EXTERNAL" "git clone failed (private repository? sign in first: devctl github setup)"
  fi
  ((DEVCTL_DRY_RUN)) && { ui_plan "dependencies (asked), web/SELinux/ACL/hosts, register $name"; return 0; }

  read -r kind template < <(site__detect "$path") || true
  [[ -n ${kind:-} ]] ||
    die "$EX_USAGE" "could not tell what kind of project this is (Laravel, Spring Boot, plain Java or static); it was cloned to $path but not set up"
  [[ $kind == none ]] && domain=""

  # The repository's own Docker setup: ask once, remember (ADR-0013).
  if compgen -G "$path/docker-compose.y*ml" >/dev/null || compgen -G "$path/compose.y*ml" >/dev/null ||
    grep -qs '"laravel/sail"' "$path/composer.json"; then
    ui_note "this repository has its own Docker setup (compose file or Laravel Sail)"
    if confirm "Use devctl's shared database servers and your host PHP/Node instead of it?" yes; then
      policy=shared
    else
      policy=repo
      ui_note "devctl will not start it; its ports must be bound to 127.0.0.1 and must not clash with devctl's"
    fi
  fi

  # PHP: the newest installed version this project's composer.lock accepts.
  local php_ver=""
  if [[ $kind == laravel ]]; then
    php_ver=$(php_choose_for "$path")
    if [[ -z $php_ver ]]; then
      php_ver=$(php_system_version)
      ui_note "no installed PHP satisfies this project's composer.lock:"
      php_needed_hint "$path" | sed 's/^/    /' >&2
      ui_note "add the PHP version it needs (e.g. devctl runtime php add 8.4), then: devctl site php $name VERSION && devctl site deps $name"
    elif ! php_is_system "$php_ver"; then
      ui_note "this project needs PHP $php_ver (your default is $(php_system_version)); devctl uses $php_ver for it"
    fi
  fi
  local -a steps=()
  [[ -f $path/composer.json ]] && steps+=("composer install (PHP ${php_ver:-default})")
  [[ -f $path/package.json ]] && steps+=("npm install, then npm run build")
  [[ $kind == proxy ]] && steps=() # Maven/Gradle fetch dependencies on the first `devctl site dev`
  if ((${#steps[@]})); then
    ui_note "installing dependencies runs scripts from this repository: ${steps[*]}"
    if confirm "Install dependencies now (only this once)?" yes; then
      if [[ -f $path/composer.json ]]; then
        run_change --desc "composer install" -- php_composer "${php_ver:-$(php_system_version)}" install --no-interaction --working-dir="$path" ||
          ui_note "composer install failed; fix it, then: devctl site deps $name"
      fi
      if [[ -f $path/package.json ]]; then
        site__node "$path" npm install --no-fund --no-audit || ui_note "npm install failed; fix and rerun it yourself"
        site__node "$path" npm run build || ui_note "npm run build failed; fix and rerun it yourself"
      fi
    fi
  fi

  local vite="-" app=""
  if [[ $kind == laravel ]]; then
    vite=$(site__vite_port_allocate "$name")
    install -m 0644 -T -- "$DEVCTL_ROOT/templates/vite/devctl.vite.config.ts" "$path/devctl.vite.config.ts"
  elif [[ $kind == proxy ]]; then
    app=$(site__app_port_allocate "$name")
    if ! grep -qsx 'devctl.env' "$path/.git/info/exclude"; then printf 'devctl.env\n' >>"$path/.git/info/exclude"; fi
  fi
  site__save "$name" "name=$name" "category=$category" "path=$path" "domain=$domain" "kind=$kind" \
    "template=${template/-/}" "tls=on" "db_engine=" "db_server=" "db_name=" "vite_port=${vite/-/}" "app_port=$app" \
    "origin=$url" "compose_policy=$policy" "php_version=$php_ver" "created=$(date +%F)"
  site__git_extras "$path"
  site__serve "$name"
}

# ---- database for an existing site (clones, or changing engine) ----------------------------

# site__guess_engine PATH KIND — the engine a project expects: Laravel's .env.example
# (DB_CONNECTION), Spring's JDBC driver dependency; "none" when it cannot tell.
site__guess_engine() {
  local path=$1 kind=$2 conn
  case $kind in
    laravel)
      # .env first (your choice), then .env.example; either may be missing in a fresh clone.
      local f
      conn=""
      for f in "$path/.env" "$path/.env.example"; do
        [[ -f $f ]] || continue
        conn=$(sed -n 's/^DB_CONNECTION=//p' -- "$f" | head -1 | tr -d '"\r ') || conn=""
        [[ -n $conn ]] && break
      done
      case $conn in mysql) echo mysql ;; mariadb) echo mariadb ;; pgsql) echo postgres ;; sqlite) echo sqlite ;; *) echo mysql ;; esac
      ;;
    proxy)
      if grep -qs 'mysql-connector' "$path/pom.xml" "$path/build.gradle" "$path/build.gradle.kts"; then echo mysql
      elif grep -qs -E "postgresql['\"<]|org.postgresql" "$path/pom.xml" "$path/build.gradle" "$path/build.gradle.kts"; then echo postgres
      else echo none
      fi
      ;;
    *) echo none ;;
  esac
}

# site_db_attach NAME ENGINE — create the site's database + user (if needed) and write the
# connection into the project: Laravel .env (created from .env.example if missing),
# Spring devctl.env. Records it in the site registry.
site_db_attach() { # NAME ENGINE [EXISTING_DB]
  local name=$1 engine=$2 existing=${3:-} db="" server="" port="" user="" pass=""
  local -A s=() srv=()
  site_load "$name" s
  if [[ -n $existing ]]; then
    local existing_info
    existing_info=$(site__existing_db "$existing")
    read -r server engine <<<"$existing_info"
  fi
  case ${s[kind]}:$engine in
    laravel:mysql | laravel:mariadb | laravel:postgres | laravel:sqlite | proxy:mysql | proxy:postgres) ;;
    *) die "$EX_USAGE" "${s[kind]} sites cannot use '$engine' (Laravel: mysql, postgres, mariadb, sqlite; Spring Boot: mysql, postgres)" ;;
  esac
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "database for $name: $engine; write the connection into the project"
    return 0
  fi
  if [[ -n $existing ]]; then
    db=$existing
    db_server_get "$server" srv
    db_server_start "$server"
    port=${srv[port]}
    user=$(secret_get "$(db_database_secrets "$server" "$db")" DB_USERNAME)
    pass=$(secret_get "$(db_database_secrets "$server" "$db")" DB_PASSWORD)
  elif [[ $engine != sqlite ]]; then
    db=$(site_db_name "$name")
    server=$(db_server_add "$engine")
    db_server_get "$server" srv
    db_server_start "$server"
    if [[ -z $(db_database_servers "$db" | grep -x -- "$server" || true) ]]; then
      db_database_create "$server" "$db"
    else
      ui_skip "database $db already exists on $server; reusing it"
    fi
    port=${srv[port]}
    user=$(secret_get "$(db_database_secrets "$server" "$db")" DB_USERNAME)
    pass=$(secret_get "$(db_database_secrets "$server" "$db")" DB_PASSWORD)
  fi

  if [[ ${s[kind]} == laravel ]]; then
    local env="${s[path]}/.env"
    if [[ ! -f $env ]]; then
      if [[ -f ${s[path]}/.env.example ]]; then cp -- "${s[path]}/.env.example" "$env"; else : >"$env"; fi
      ui_ok "created .env from .env.example"
    fi
    chmod 600 -- "$env"
    env_set "$env" APP_URL "https://${s[domain]}"
    if [[ $engine == sqlite ]]; then
      env_set "$env" DB_CONNECTION sqlite
      mkdir -p -- "${s[path]}/database"
      [[ -f ${s[path]}/database/database.sqlite ]] || touch -- "${s[path]}/database/database.sqlite"
    else
      case $engine in mysql) env_set "$env" DB_CONNECTION mysql ;; mariadb) env_set "$env" DB_CONNECTION mariadb ;; postgres) env_set "$env" DB_CONNECTION pgsql ;; esac
      env_set "$env" DB_HOST 127.0.0.1
      env_set "$env" DB_PORT "$port"
      env_set "$env" DB_DATABASE "$db"
      env_set "$env" DB_USERNAME "$user"
      env_set "$env" DB_PASSWORD "$pass"
    fi
    if ! grep -qE '^APP_KEY=.+' "$env"; then
      if [[ -f ${s[path]}/vendor/autoload.php ]]; then
        run_change --desc "Generate APP_KEY" -- php_run "$(site_php "$name")" "${s[path]}/artisan" key:generate --force --no-interaction ||
          ui_note "php artisan key:generate failed; run it yourself"
      else
        ui_note "APP_KEY is empty and dependencies are not installed: run composer install, then php artisan key:generate"
      fi
    fi
  else
    local file="${s[path]}/devctl.env" url
    case $engine in mysql) url="jdbc:mysql://127.0.0.1:$port/$db" ;; postgres) url="jdbc:postgresql://127.0.0.1:$port/$db" ;; esac
    [[ -f $file ]] || : >"$file"
    chmod 600 -- "$file"
    env_set "$file" SPRING_DATASOURCE_URL "$url"
    env_set "$file" SPRING_DATASOURCE_USERNAME "$user"
    env_set "$file" SPRING_DATASOURCE_PASSWORD "$pass"
    if [[ -d ${s[path]}/.git/info ]] && ! grep -qsx 'devctl.env' "${s[path]}/.git/info/exclude"; then
      printf 'devctl.env\n' >>"${s[path]}/.git/info/exclude"
    fi
  fi
  site__set "$name" db_engine "$engine"
  site__set "$name" db_server "$server"
  site__set "$name" db_name "$db"
  # A running site holds its database server.
  site_running "$name" && [[ -n $server ]] && db_server_acquire "$server" "$name"
  ui_ok "database ready: $engine${db:+ — database and user $db on $server}"
}

# site_db_fill NAME MODE [FILE] — migrate | import FILE | none
site_db_fill() {
  local name=$1 mode=$2 file=${3:-}
  local -A s=()
  site_load "$name" s
  case $mode in
    none) ui_skip "database left empty" ;;
    migrate)
      if [[ ${s[kind]} == laravel ]]; then
        [[ -f ${s[path]}/vendor/autoload.php ]] || die "$EX_PRECONDITION" "dependencies are not installed (composer install), so migrations cannot run"
        ui_step "Running migrations"
        run_change --desc "Migrate" -- php_run "$(site_php "$name")" "${s[path]}/artisan" migrate --force --no-interaction || die "$EX_EXTERNAL" "migrations failed"
      else
        ui_note "Spring Boot creates its tables when it starts (spring.jpa.hibernate.ddl-auto / Flyway / Liquibase)"
        [[ -f ${s[path]}/devctl.env ]] && env_set "${s[path]}/devctl.env" SPRING_JPA_HIBERNATE_DDL_AUTO update
      fi
      ;;
    import)
      [[ -n $file && -r $file ]] || die "$EX_NOTFOUND" "import needs a readable file (--file PATH)"
      [[ -n ${s[db_name]:-} ]] || die "$EX_PRECONDITION" "$name has no database server to import into (SQLite: copy the file into database/)"
      "$DEVCTL_ROOT/bin/devctl" --yes db import "${s[db_name]}" "$file" --server "${s[db_server]}" ||
        die "$EX_EXTERNAL" "import failed"
      ;;
    *) die "$EX_USAGE" "fill must be migrate, import or none" ;;
  esac
}

# ---- run state ----------------------------------------------------------------------------

site__state_file() { printf '%s/sites/%s.running\n' "$DEVCTL_RUN_DIR" "$1"; }
site_running() { [[ -f $(site__state_file "$1") ]]; }

site_start() {
  local name=$1
  local -A s=()
  site_load "$name" s
  [[ -n ${s[db_server]:-} ]] && db_server_acquire "${s[db_server]}" "$name"
  site__serve "$name"
  ((DEVCTL_DRY_RUN)) && return 0
  ensure_private_dir "${DEVCTL_RUN_DIR}/sites"
  : >"$(site__state_file "$name")"
}

# site_stop NAME — the site answers "stopped" (503) and releases its database server.
site_stop() {
  local name=$1
  local -A s=()
  site_load "$name" s
  if [[ ${s[kind]} != none ]]; then
    web_render stopped "$name" "${s[domain]}" "${s[tls]}" - - - -
    web_needs_apply && web_apply
  fi
  [[ -n ${s[db_server]:-} ]] && db_server_release "${s[db_server]}" "$name"
  ((DEVCTL_DRY_RUN)) || rm -f -- "$(site__state_file "$name")"
}

# site_delete NAME — removes devctl's setup only. Folder and database stay.
site_delete() {
  local name=$1
  local -A s=()
  site_load "$name" s
  [[ -n ${s[db_server]:-} ]] && db_server_release "${s[db_server]}" "$name"
  rm -f -- "$(site__state_file "$name")"
  if [[ ${s[kind]} != none ]]; then
    web_remove "$name"
    web_needs_apply && web_apply
    dns_remove "${s[domain]}"
    dns_apply
  fi
  if [[ -d ${s[path]} && ( ${s[kind]} == laravel || ${s[kind]} == static ) ]]; then
    priv_run --desc "Remove SELinux labels" project-unlabel "${s[path]}" || ui_note "could not remove the SELinux labels"
    site__acl_revoke "${s[path]}"
  fi
  run_change --desc "Forget the site" -- rm -f -- "$SITES_REGISTRY/$name.conf"
}
