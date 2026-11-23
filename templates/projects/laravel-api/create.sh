# shellcheck shell=bash
# Template laravel-api: plain Laravel + `php artisan install:api` (routes/api.php, Sanctum).
LARAVEL_PACKAGE=laravel/laravel
LARAVEL_VERSION=^13.0
LARAVEL_FRONTEND=no
# shellcheck source=templates/projects/_laravel/laravel.sh
source "$DEVCTL_ROOT/templates/projects/_laravel/laravel.sh"

laravel_after_env() { # PATH — before migrations, so Sanctum's tokens table is migrated too
  local path=$1 model="$1/app/Models/User.php"
  ui_step "Adding the API layer (php artisan install:api)"
  run_change --desc "Install API (Sanctum)" -- php "$path/artisan" install:api --without-migration-prompt --no-interaction ||
    die "$EX_EXTERNAL" "php artisan install:api failed"
  # Verified 2026-11-05 (Laravel 13.11, Sanctum 4.3): install:api does not publish Sanctum's
  # personal_access_tokens migration; publish it so token auth works.
  if ! compgen -G "$path/database/migrations/*_create_personal_access_tokens_table.php" >/dev/null; then
    run_change --desc "Publish Sanctum's migration" -- php "$path/artisan" vendor:publish --tag=sanctum-migrations --no-interaction ||
      die "$EX_EXTERNAL" "could not publish Sanctum's migration"
  fi
  # install:api asks you to add the HasApiTokens trait to the User model: do it.
  if [[ -f $model ]] && ! grep -q 'HasApiTokens' "$model"; then
    if grep -q '^use Illuminate\\Notifications\\Notifiable;$' "$model" && grep -qE '^    use HasFactory, Notifiable;$' "$model"; then
      sed -i -e 's/^use Illuminate\\Notifications\\Notifiable;$/&\nuse Laravel\\Sanctum\\HasApiTokens;/' \
        -e 's/^    use HasFactory, Notifiable;$/    use HasApiTokens, HasFactory, Notifiable;/' -- "$model"
    else
      ui_note "add the Laravel\\Sanctum\\HasApiTokens trait to app/Models/User.php yourself (unexpected layout)"
    fi
  fi
}
