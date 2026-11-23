# shellcheck shell=bash
# summary: Projects: create from a template or clone, list, start/stop, dev (Vite), delete

# shellcheck source=lib/services/sites.sh
source "${DEVCTL_ROOT:?}/lib/services/sites.sh"

register_action site.create site.clone site.start site.stop site.delete site.db site.php site.deps

SITE_SHIFT=1
site__take() { # VAR "$@" — "--x value" or "--x=value"
  local -n __out=$1
  if [[ $2 == *=* ]]; then __out=${2#*=}; SITE_SHIFT=1
  else (($# >= 3)) || die "$EX_USAGE" "$2 needs a value"; __out=$3; SITE_SHIFT=2; fi
}

# site__choose PROMPT DEFAULT CHOICE... — numbered choice in a terminal (used when a flag is missing).
site__choose() {
  local prompt=$1 default=$2 reply i
  shift 2
  [[ -t 0 ]] || die "$EX_USAGE" "$prompt: pass it as an option (no terminal to ask)"
  for ((i = 1; i <= $#; i++)); do printf '  %d) %s\n' "$i" "${!i}" >&2; done
  while true; do
    read -r -p "$prompt [$default]: " reply || die "$EX_ABORTED" "aborted"
    [[ -z $reply ]] && { printf '%s\n' "$default"; return; }
    if is_uint "$reply" && ((reply >= 1 && reply <= $#)); then printf '%s\n' "${!reply}"; return; fi
    is_in_list "$reply" "$@" && { printf '%s\n' "$reply"; return; }
    printf 'Choose a number from the list.\n' >&2
  done
}

site__templates() {
  local d
  for d in "$SITES_TEMPLATES"/*/; do
    d=${d%/}
    [[ -f $d/template.conf ]] && printf '%s\n' "${d##*/}"
  done
}

cmd_site() { cmd_site_list "$@"; }

cmd_site_list() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl site list"
  local name
  local -a names=() rows=()
  local -A s=()
  mapfile -t names < <(site_names)
  for name in "${names[@]}"; do
    site_load "$name" s
    rows+=("$name" "${s[category]}" "${s[kind]}" "${s[domain]:+https://${s[domain]}}" "${s[db_engine]:-}${s[db_name]:+ · ${s[db_name]}}" \
      "$(site_running "$name" && echo running || echo stopped)" "${s[path]}" "${s[db_name]:-}" "${s[db_server]:-}")
  done
  if ((DEVCTL_JSON)); then
    jq -n --argjson r "$(json_array "${rows[@]}")" \
      '[range(0; $r | length; 9) as $i | {name: $r[$i], category: $r[$i + 1], kind: $r[$i + 2],
        url: $r[$i + 3], db_engine: $r[$i + 4], state: $r[$i + 5], path: $r[$i + 6],
        db_name: $r[$i + 7], db_server: $r[$i + 8]}]'
    return 0
  fi
  ((${#names[@]})) || { ui_skip "no sites yet (devctl site create NAME)"; return 0; }
  {
    printf 'SITE\tCATEGORY\tKIND\tURL\tDATABASE\tSTATE\n'
    for ((i = 0; i < ${#rows[@]}; i += 9)); do
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${rows[i]}" "${rows[i + 1]}" "${rows[i + 2]}" "${rows[i + 3]:--}" "${rows[i + 4]:--}" "${rows[i + 5]}"
    done
  } | ui_table
}

cmd_site_create() {
  local name="" category="" template="" engine="" existing=""
  while (($#)); do
    case $1 in
      --category | --category=*) site__take category "$@"; shift "$SITE_SHIFT" ;;
      --template | --template=*) site__take template "$@"; shift "$SITE_SHIFT" ;;
      --db | --db=*) site__take engine "$@"; shift "$SITE_SHIFT" ;;
      --use-db | --use-db=*) site__take existing "$@"; shift "$SITE_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl site create NAME [--category C] [--template T] [--db ENGINE | --use-db EXISTING_DB]" ;;
      *) [[ -z $name ]] || die "$EX_USAGE" "one site at a time"; name=$1; shift ;;
    esac
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl site create NAME [--category C] [--db ENGINE] [--template T]"
  local -a list=()
  # shellcheck disable=SC2046  # space-separated list from config
  [[ -n $category ]] || category=$(site__choose "Category" personal $(config_get projects.categories))
  site_validate_new "$name" "$category"
  mapfile -t list < <(site__templates)
  [[ -n $template ]] || template=$(site__choose "Template" laravel-inertia-react "${list[@]}")
  is_in_list "$template" "${list[@]}" || die "$EX_VALIDATION" "unknown template '$template' (choose: ${list[*]})"
  local -A tpl=()
  kv_read "$SITES_TEMPLATES/$template/template.conf" tpl
  if [[ -n $existing ]]; then
    [[ -z $engine ]] || die "$EX_USAGE" "--use-db and --db cannot be combined"
    local ex_server
    local existing_info
    existing_info=$(site__existing_db "$existing")
    read -r ex_server engine <<<"$existing_info"
    # shellcheck disable=SC2086  # space-separated list from the template
    is_in_list "$engine" ${tpl[db_engines]:-} || die "$EX_VALIDATION" "${tpl[name]} cannot use $existing ($engine)"
  elif [[ -z ${tpl[db_engines]:-} ]]; then
    [[ -z $engine || $engine == none ]] || die "$EX_VALIDATION" "${tpl[name]} has no database"
    engine=none
  else
    # The database engine is asked every time (requirements §3.1).
    # shellcheck disable=SC2086  # space-separated list from the template
    [[ -n $engine ]] || engine=$(site__choose "Database engine" "${tpl[default_db_engine]}" ${tpl[db_engines]})
    # shellcheck disable=SC2086
    is_in_list "$engine" ${tpl[db_engines]} || die "$EX_VALIDATION" "$template supports: ${tpl[db_engines]}"
  fi

  ui_header "New site $name"
  printf '  %-10s %s\n' template "${tpl[name]} — ${tpl[description]:-}" folder "$(site_path "$name" "$category")"
  [[ ${tpl[kind]} == none ]] || printf '  %-10s %s\n' url "https://$(site_domain "$name")"
  case ${existing:+existing}$engine in
    existing*) printf '  %-10s %s\n' database "the existing $existing on $ex_server ($engine), used as is (no migrations)" ;;
    none) ;;
    sqlite) printf '  %-10s %s\n' database "SQLite file in the project" ;;
    *) printf '  %-10s %s\n' database "$engine — database and user $(site_db_name "$name") with a new password" ;;
  esac
  [[ ${tpl[kind]} == none ]] || printf '  %-10s %s\n' admin "local name, web server config$([[ ${tpl[kind]} != proxy ]] && printf ', SELinux labels') (password asked)"
  confirm_or_abort "Create it?" yes
  site_create "$name" "$category" "$template" "$engine" "$existing"
  ((DEVCTL_DRY_RUN)) && return 0
  case ${tpl[kind]} in
    laravel) ui_ok "https://$(site_domain "$name") is ready (dev server with live reload: devctl site dev $name)" ;;
    static) ui_ok "https://$(site_domain "$name") is ready (edit the files, reload the page)" ;;
    proxy) ui_ok "created; run it with: devctl site dev $name — then open https://$(site_domain "$name")" ;;
    none) ui_ok "created in $(site_path "$name" "$category"); run it with: devctl site dev $name" ;;
  esac
}

cmd_site_clone() {
  local url="" name="" category="" engine="" fill="" file="" existing=""
  while (($#)); do
    case $1 in
      --name | --name=*) site__take name "$@"; shift "$SITE_SHIFT" ;;
      --category | --category=*) site__take category "$@"; shift "$SITE_SHIFT" ;;
      --db | --db=*) site__take engine "$@"; shift "$SITE_SHIFT" ;;
      --use-db | --use-db=*) site__take existing "$@"; shift "$SITE_SHIFT" ;;
      --fill | --fill=*) site__take fill "$@"; shift "$SITE_SHIFT" ;;
      --file | --file=*) site__take file "$@"; shift "$SITE_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl site clone OWNER/REPO|URL [--name NAME] [--category C] [--db E|auto|none | --use-db EXISTING_DB] [--fill migrate|import|none] [--file PATH]" ;;
      *) url=$1; shift ;;
    esac
  done
  [[ -n $url ]] || die "$EX_USAGE" "usage: devctl site clone OWNER/REPO|URL [--name NAME] [--category C]"
  # Check every option before asking anything.
  [[ -z $fill ]] || is_in_list "$fill" migrate import none || die "$EX_USAGE" "--fill must be migrate, import or none"
  [[ -z $engine ]] || is_in_list "$engine" auto mysql postgres mariadb sqlite none || die "$EX_USAGE" "--db must be auto, mysql, postgres, mariadb, sqlite or none"
  [[ -z $existing || -z $engine ]] || die "$EX_USAGE" "--use-db and --db cannot be combined"
  [[ -z $existing ]] || site__existing_db "$existing" >/dev/null
  [[ $fill != import || -r ${file/#\~/$HOME} ]] || [[ -z $file ]] || die "$EX_NOTFOUND" "cannot read $file"
  if [[ -z $name ]]; then
    name=${url##*/}
    name=${name%.git}
    name=$(tr 'A-Z_.' 'a-z--' <<<"$name" | tr -s '-')
    name=${name#-}
    name=${name%-}
    ui_note "using the name '$name' (change it with --name)"
  fi
  # shellcheck disable=SC2046
  [[ -n $category ]] || category=$(site__choose "Category" elden $(config_get projects.categories))
  site_validate_new "$name" "$category"
  confirm_or_abort "Clone $url into $(site_path "$name" "$category") and set it up as a site?" yes
  site_clone "$url" "$name" "$category"
  ((DEVCTL_DRY_RUN)) && { ui_plan "database: $([[ -n $existing ]] && echo "existing $existing" || echo "${engine:-asked}") (fill: ${fill:-asked})"; return 0; }
  local -A s=()
  site_load "$name" s
  # The database is always set up for clones; how to fill it is asked (or given).
  if [[ ${s[kind]} == laravel || ${s[kind]} == proxy ]]; then
    site__db_questions "$name" "$engine" "$fill" "$file" "$existing"
    if [[ $SITE_DB_ENGINE != none ]]; then
      site_db_attach "$name" "$SITE_DB_ENGINE" "$SITE_DB_EXISTING"
      site_db_fill "$name" "$SITE_DB_FILL" "$SITE_DB_FILE" || ui_note "the database is set up, but filling it failed; retry with: devctl site db $name"
    fi
    site_load "$name" s
  fi
  case ${s[kind]} in
    laravel) ui_ok "https://${s[domain]} is set up${s[db_engine]:+ with its ${s[db_engine]} database}" ;;
    proxy) ui_ok "set up; run it with: devctl site dev $name — then open https://${s[domain]}" ;;
    none) ui_ok "cloned to ${s[path]}; run it with: devctl site dev $name" ;;
    *) ui_ok "https://${s[domain]} is set up" ;;
  esac
}

cmd_site_templates() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl site templates"
  local t
  local -A tpl=()
  {
    printf 'TEMPLATE\tNAME\tDATABASES\tDESCRIPTION\n'
    while IFS= read -r t; do
      kv_read "$SITES_TEMPLATES/$t/template.conf" tpl
      printf '%s\t%s\t%s\t%s\n' "$t" "${tpl[name]}" "${tpl[db_engines]:--}" "${tpl[description]:-}"
    done < <(site__templates)
  } | ui_table
}

# site__db_questions NAME [ENGINE] [FILL] [FILE] — fill in what was not given: the engine
# (suggested from the project), then how to fill the database. Asked in a terminal.
SITE_DB_ENGINE="" SITE_DB_FILL="" SITE_DB_FILE="" SITE_DB_EXISTING=""
site__db_questions() { # NAME [ENGINE] [FILL] [FILE] [EXISTING_DB]
  local name=$1 engine=${2:-} fill=${3:-} file=${4:-} existing=${5:-} guess
  local -A s=()
  site_load "$name" s
  # Nothing chosen and a terminal: offer the databases devctl already has.
  if [[ -z $engine && -z $existing && -t 0 ]] && ((!DEVCTL_ASSUME_YES)) &&
    [[ ${s[kind]} == laravel || ${s[kind]} == proxy ]]; then
    local -a known=()
    [[ -f $DB_DATABASES_FILE ]] && mapfile -t known < <(cut -f1 -- "$DB_DATABASES_FILE" | sort -u)
    if ((${#known[@]})) && [[ $(site__choose "Database for $name: a new one, or one you already have (${known[*]})" new new existing) == existing ]]; then
      existing=$(site__choose "Which existing database" "${known[0]}" "${known[@]}")
    fi
  fi
  if [[ -n $existing ]]; then
    # A database another site already uses: its tables stay; migrating is opt-in.
    local server
    local existing_info
    existing_info=$(site__existing_db "$existing")
    read -r server engine <<<"$existing_info"
    case ${s[kind]}:$engine in
      laravel:mysql | laravel:mariadb | laravel:postgres | proxy:mysql | proxy:postgres) ;;
      *) die "$EX_USAGE" "${s[kind]} sites cannot use $existing ($engine on $server)" ;;
    esac
    if [[ -z $fill ]]; then
      if [[ -t 0 ]] && ((!DEVCTL_ASSUME_YES)); then
        fill=$(site__choose "$existing already has its tables: leave it as is, run this project's migrations, or import a dump" none none migrate import)
      else
        fill=none
      fi
    fi
  fi
  guess=$(site__guess_engine "${s[path]}" "${s[kind]}")
  [[ $engine == auto ]] && engine=$guess
  if [[ -z $engine ]]; then
    if [[ -t 0 ]] && ((!DEVCTL_ASSUME_YES)); then
      case ${s[kind]} in
        laravel) engine=$(site__choose "Database for $name (the project expects $guess)" "$guess" mysql postgres mariadb sqlite none) ;;
        proxy) engine=$(site__choose "Database for $name" "$guess" mysql postgres none) ;;
        *) engine=none ;;
      esac
    else
      engine=$guess
    fi
  fi
  if [[ $engine != none && -z $fill ]]; then
    if [[ -t 0 ]] && ((!DEVCTL_ASSUME_YES)); then
      fill=$(site__choose "Fill the database: run the migrations, import a dump file, or leave it empty" migrate migrate import none)
    else
      fill=migrate
    fi
  fi
  if [[ $fill == import && -z $file ]]; then
    [[ -t 0 ]] || die "$EX_USAGE" "import needs --file PATH"
    read -r -p "Dump file to import (.sql, .sql.gz, .dump, .gz): " file
    file=${file/#\~/$HOME}
  fi
  SITE_DB_ENGINE=$engine SITE_DB_FILL=${fill:-none} SITE_DB_FILE=$file SITE_DB_EXISTING=$existing
}

# db: attach a database to an existing site (e.g. a clone) and fill it.
cmd_site_db() {
  local name="" engine="" fill="" file="" existing=""
  while (($#)); do
    case $1 in
      --use | --use=*) site__take existing "$@"; shift "$SITE_SHIFT" ;;
      --engine | --engine=*) site__take engine "$@"; shift "$SITE_SHIFT" ;;
      --fill | --fill=*) site__take fill "$@"; shift "$SITE_SHIFT" ;;
      --file | --file=*) site__take file "$@"; shift "$SITE_SHIFT" ;;
      -*) die "$EX_USAGE" "usage: devctl site db NAME [--engine E|auto | --use EXISTING_DB] [--fill migrate|import|none] [--file PATH]" ;;
      *) name=$1; shift ;;
    esac
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl site db NAME [--engine E|auto | --use EXISTING_DB] [--fill migrate|import|none] [--file PATH]"
  [[ -z $fill ]] || is_in_list "$fill" migrate import none || die "$EX_USAGE" "--fill must be migrate, import or none"
  [[ -z $existing || -z $engine ]] || die "$EX_USAGE" "--use and --engine cannot be combined (the existing database decides the engine)"
  site__db_questions "$name" "$engine" "$fill" "$file" "$existing"
  [[ $SITE_DB_ENGINE == none ]] && { ui_skip "no database for $name"; return 0; }
  site_db_attach "$name" "$SITE_DB_ENGINE" "$SITE_DB_EXISTING"
  ((DEVCTL_DRY_RUN)) && { ui_plan "fill: $SITE_DB_FILL"; return 0; }
  site_db_fill "$name" "$SITE_DB_FILL" "$SITE_DB_FILE"
}

# php NAME [VERSION] — show or change the site's PHP version.
cmd_site_php() {
  (($# >= 1 && $# <= 2)) || die "$EX_USAGE" "usage: devctl site php NAME [VERSION]"
  local name=$1 v=${2:-}
  local -A s=()
  site_load "$name" s
  [[ ${s[kind]} == laravel ]] || die "$EX_USAGE" "$name is not a PHP site"
  if [[ -z $v ]]; then
    v=$(site_php "$name")
    printf 'PHP %s for %s — in its folder use: %s artisan …, %s %s install\n' "$v" "$name" \
      "$(php_bin "$v" | sed 's#/usr/bin/##')" "$(php_bin "$v" | sed 's#/usr/bin/##')" "$(command -v composer)"
    return 0
  fi
  php_valid_version "$v" || die "$EX_VALIDATION" "invalid PHP version '$v'"
  if [[ ! -x $(php_bin "$v") ]] || ! php_fpm_ready "$v"; then die "$EX_PRECONDITION" "PHP $v is not set up: devctl runtime php add $v"; fi
  ((DEVCTL_DRY_RUN)) && { ui_plan "use PHP $v for $name; apply the web server configuration"; return 0; }
  site__set "$name" php_version "$v"
  site__serve "$name"
  ui_ok "$name now runs on PHP $v"
}

# deps NAME — install dependencies again (e.g. after a failed first install), with the
# site's PHP and Node versions. Runs the repository's own scripts: asks first.
cmd_site_deps() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl site deps NAME"
  local name=$1 v
  local -A s=()
  site_load "$name" s
  local -a steps=()
  [[ -f ${s[path]}/composer.json ]] && steps+=("composer install")
  [[ -f ${s[path]}/package.json ]] && steps+=("npm install, npm run build")
  ((${#steps[@]})) || { ui_skip "no Composer or npm dependencies"; return 0; }
  ui_note "this runs scripts from the repository: ${steps[*]}"
  confirm_or_abort "Install dependencies of $name?" yes
  if [[ -f ${s[path]}/composer.json ]]; then
    v=$(site_php "$name")
    run_change --desc "composer install (PHP $v)" -- php_composer "$v" install --no-interaction --working-dir="${s[path]}" ||
      die "$EX_EXTERNAL" "composer install failed (wrong PHP version? devctl site php $name VERSION)"
  fi
  if [[ -f ${s[path]}/package.json ]]; then
    site__node "${s[path]}" npm install --no-fund --no-audit || die "$EX_EXTERNAL" "npm install failed"
    site__node "${s[path]}" npm run build || ui_note "npm run build failed"
  fi
  ((DEVCTL_DRY_RUN)) || ui_ok "dependencies installed"
}

cmd_site_info() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl site info NAME"
  local -A s=()
  site_load "$1" s
  if ((DEVCTL_JSON)); then
    local -a pairs=()
    local k
    for k in "${!s[@]}"; do pairs+=(--arg "$k" "${s[$k]}"); done
    jq -n '$ARGS.named' "${pairs[@]}"
    return 0
  fi
  local k
  for k in name category kind path domain tls php_version db_engine db_server db_name vite_port app_port origin compose_policy created; do
    [[ -n ${s[$k]:-} ]] && printf '%s\t%s\n' "$k" "${s[$k]}"
  done | ui_table
}

cmd_site_start() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl site start NAME"
  local -A s=()
  site_load "$1" s
  [[ ${s[kind]} == none ]] && die "$EX_USAGE" "$1 has no website; run it with: devctl site dev $1"
  site_start "$1"
  ((DEVCTL_DRY_RUN)) || ui_ok "$1 is running: https://$(site_domain "$1")"
}

cmd_site_stop() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl site stop NAME"
  site_stop "$1"
  ((DEVCTL_DRY_RUN)) || ui_ok "$1 stopped (its database server stops when no running site uses it)"
}

cmd_site_delete() {
  local name="" db_choice="" others="" drop=0
  while (($#)); do
    case $1 in
      --with-db) db_choice=delete; shift ;;
      --keep-db) db_choice=keep; shift ;;
      -*) die "$EX_USAGE" "usage: devctl site delete NAME [--with-db | --keep-db]" ;;
      *) [[ -z $name ]] || die "$EX_USAGE" "usage: devctl site delete NAME [--with-db | --keep-db]"; name=$1; shift ;;
    esac
  done
  [[ -n $name ]] || die "$EX_USAGE" "usage: devctl site delete NAME [--with-db | --keep-db]"
  local -A s=()
  site_load "$name" s
  local db=${s[db_name]:-} server=${s[db_server]:-}
  # Only a database devctl has on record can be deleted from here.
  if [[ -n $db && -n $server ]] && ! db_database_servers "$db" | grep -qx -- "$server"; then
    [[ $db_choice != delete ]] || die "$EX_NOTFOUND" "devctl has no record of the database $db on $server; nothing to delete (use --keep-db)"
    db=""
  fi
  if [[ -n $db && -n $server ]]; then
    # A database another site also uses is never deleted with this one.
    others=$(db_database_sites "$server" "$db" | grep -vx -- "$name" | paste -sd, - || true)
    others=${others//,/, }
    if [[ -n $others ]]; then
      [[ $db_choice != delete ]] || die "$EX_CONFLICT" "the database $db is also used by $others; delete those sites first, or use --keep-db"
    elif [[ $db_choice == delete ]]; then
      drop=1
    elif [[ -z $db_choice && -t 0 ]] && ((!DEVCTL_ASSUME_YES && !DEVCTL_DRY_RUN)); then
      confirm "Also delete its database $db on $server (all its tables and data)?" no && drop=1
    fi
  elif [[ $db_choice == delete ]]; then
    die "$EX_USAGE" "$name has no devctl database to delete${s[db_engine]:+ (${s[db_engine]}: the file stays in the project folder)}"
  fi
  ui_header "Delete the devctl setup of $name"
  if ((drop)); then
    printf '  %s\n' "removed: web server config, the name ${s[domain]}, SELinux labels, Caddy's access" \
      "DELETED: the database $db on $server, its user and password — all its tables and data" \
      "kept: the folder ${s[path]}"
  else
    printf '  %s\n' "removed: web server config, the name ${s[domain]}, SELinux labels, Caddy's access" \
      "kept: the folder ${s[path]}${db:+ and the database $db on $server}${others:+ (also used by $others)}"
  fi
  confirm_typed "$name" || die "$EX_ABORTED" "aborted; nothing changed"
  site_delete "$name"
  ((drop)) && db_database_drop "$server" "$db"
  ((DEVCTL_DRY_RUN)) && return 0
  if ((drop)); then
    ui_ok "$name is no longer served and its database $db is deleted; the folder is untouched"
  else
    ui_ok "$name is no longer served; its folder${db:+ and database} are untouched"
    [[ -n $db && -z $others ]] && ui_note "the database stays; delete it later with: devctl db drop $db"
  fi
  return 0
}

# dev: the project's development process in the foreground (Ctrl+C stops it):
# Laravel → Vite with live reload over HTTPS; Spring Boot → the app; plain Java → compile + run.
cmd_site_dev() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl site dev NAME"
  local -A s=() tpl=()
  site_load "$1" s
  case ${s[kind]} in
    static) die "$EX_USAGE" "$1 is static: edit the files and reload https://${s[domain]}" ;;
    proxy | none)
      site__template_load "${s[template]:?}" tpl
      declare -F tpl_dev >/dev/null || die "$EX_USAGE" "${tpl[name]} has no dev command"
      if [[ ${s[kind]} == proxy ]]; then
        site_running "$1" || site_start "$1"
        ui_ok "Starting ${tpl[name]} on 127.0.0.1:${s[app_port]} — open https://${s[domain]} (Ctrl+C stops it)"
      fi
      tpl_dev "${s[path]}" "$1" "${s[app_port]:-}"
      return
      ;;
  esac
  [[ -n ${s[vite_port]:-} ]] || die "$EX_USAGE" "$1 has no front end to develop (API); it is served at https://${s[domain]}"
  [[ -f ${s[path]}/devctl.vite.config.ts ]] ||
    install -m 0644 -T -- "$DEVCTL_ROOT/templates/vite/devctl.vite.config.ts" "${s[path]}/devctl.vite.config.ts"
  site_running "$1" || site_start "$1"
  ui_ok "Vite: https://${s[domain]}:${s[vite_port]} — open https://${s[domain]} (Ctrl+C stops it)"
  DEVCTL_SITE_HOST=${s[domain]} DEVCTL_VITE_PUBLIC_PORT=${s[vite_port]} \
    DEVCTL_VITE_PORT=$((s[vite_port] + SITES_VITE_OFFSET)) DEVCTL_APP_URL="https://${s[domain]}" \
    NODE_EXTRA_CA_CERTS="$DEVCTL_DATA_DIR/ca/root.crt" \
    site__node "${s[path]}" npx vite --config devctl.vite.config.ts
}

cmd_site_open() {
  (($# == 1)) || die "$EX_USAGE" "usage: devctl site open NAME"
  local -A s=()
  site_load "$1" s
  xdg-open "https://${s[domain]}" >/dev/null 2>&1 || printf 'https://%s\n' "${s[domain]}"
}

complete_site() {
  case $1:$2 in
    args:start | args:stop | args:delete | args:dev | args:open | args:info) [[ $3 == 1 ]] && site_names ;;
    flags:create) printf '%s\n' --category --db --use-db --template ;;
    args:create) ;;
    flags:clone) printf '%s\n' --name --category --db --use-db --fill --file ;;
    flags:db) printf '%s\n' --engine --use --fill --file ;;
    flags:delete) printf '%s\n' --with-db --keep-db ;;
    args:db | args:deps) [[ $3 == 1 ]] && site_names ;;
    args:php) [[ $3 == 1 ]] && site_names; [[ $3 == 2 ]] && php_versions ;;
  esac
  return 0
}

help_site() {
  cat <<'HELP'
Usage: devctl site [list]                                   your sites and their state
       devctl site templates                                 available project templates
       devctl site php NAME [VERSION]                         show or change the site's PHP version
       devctl site deps NAME                                  composer/npm install again (site's PHP/Node)
       devctl site db NAME [--engine E|auto | --use DB] [--fill migrate|import|none] [--file F]
                                                             attach a database to a site and fill it
       devctl site create NAME [--category C] [--db ENGINE]  Laravel + Inertia + React project
       devctl site clone OWNER/REPO|URL [--name N] [--category C] [--db E | --use-db DB]
                                                             clone and set up (GitHub: devctl github)
       devctl site start|stop NAME                           database server on/off with the site
       devctl site dev NAME                                  Vite with live reload over HTTPS
       devctl site open NAME | info NAME
       devctl site delete NAME [--with-db | --keep-db]       type NAME to confirm; asks whether to
                                                             delete its database too (default: keep)

Every site gets https://NAME.test (trusted), its own database and user (create), read-only
access for the web server and SELinux labels; Laravel's storage/ and bootstrap/cache/ are
writable by PHP. Delete keeps the folder, and the database unless you say so (--with-db);
a database other sites also use is always kept.

--use-db DB / --use DB connect to a database devctl already has (see devctl db list --databases):
same database, same user, its tables kept as they are (migrations only with --fill migrate).
In a terminal, clone and db also ask "a new one, or one you already have".
HELP
}
