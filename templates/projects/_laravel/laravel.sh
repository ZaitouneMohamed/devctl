# shellcheck shell=bash
# Shared steps of the Laravel templates (not a template itself: no template.conf).
# Each Laravel template's create.sh sets LARAVEL_PACKAGE, LARAVEL_VERSION, LARAVEL_FRONTEND
# (yes/no) and may define laravel_after_env PATH (runs before migrations).

tpl_create() { # PATH NAME ENGINE
  run_change --desc "Create project" -- composer create-project --no-interaction --prefer-dist \
    -- "$LARAVEL_PACKAGE" "$1" "$LARAVEL_VERSION" || die "$EX_EXTERNAL" "composer create-project failed"
}

tpl_configure() { # PATH NAME ENGINE DB_PORT DB USER PASS
  local path=$1 env="$1/.env"
  env_set "$env" APP_URL "https://$(site_domain "$2")"
  case $3 in
    sqlite)
      env_set "$env" DB_CONNECTION sqlite
      [[ -f $path/database/database.sqlite ]] || touch -- "$path/database/database.sqlite"
      ;;
    *)
      case $3 in mysql) env_set "$env" DB_CONNECTION mysql ;; mariadb) env_set "$env" DB_CONNECTION mariadb ;; postgres) env_set "$env" DB_CONNECTION pgsql ;; esac
      env_set "$env" DB_HOST 127.0.0.1
      env_set "$env" DB_PORT "$4"
      env_set "$env" DB_DATABASE "$5"
      env_set "$env" DB_USERNAME "$6"
      env_set "$env" DB_PASSWORD "$7"
      ;;
  esac
  chmod 600 -- "$env"
  if declare -F laravel_after_env >/dev/null; then laravel_after_env "$path"; fi
  if [[ -n ${SITE_EXISTING_DB:-} ]]; then
    ui_skip "migrations not run: the existing database is used as is"
  else
    ui_step "Running migrations"
    run_change --desc "Migrate" -- php "$path/artisan" migrate --force --no-interaction || die "$EX_EXTERNAL" "migrations failed"
  fi
  if [[ $LARAVEL_FRONTEND == yes ]]; then
    ui_step "Installing front-end packages and building assets"
    site__node "$path" npm install --no-fund --no-audit || die "$EX_EXTERNAL" "npm install failed"
    site__node "$path" npm run build || die "$EX_EXTERNAL" "npm run build failed"
  fi
}
