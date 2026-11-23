# shellcheck shell=bash
# php.sh — PHP versions side by side (ADR-0020): Fedora's PHP ("system") plus Remi's
# phpXY packages. A version string is MAJOR.MINOR (e.g. 8.4); a site records its own.

# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

[[ -n ${__DEVCTL_PHP_SH:-} ]] && return 0
__DEVCTL_PHP_SH=1

php_valid_version() { [[ $1 =~ ^8\.[0-9]$ ]]; }

# php_system_version — Fedora's PHP (e.g. 8.5).
php_system_version() {
  command -v php >/dev/null || return 1
  php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION, "\n";' 2>/dev/null
}

# php_versions — installed versions, newest first.
php_versions() {
  local f v
  {
    php_system_version || true
    for f in /usr/bin/php8[0-9]; do
      [[ -x $f ]] || continue
      v=${f##*/php}
      printf '%s.%s\n' "${v:0:1}" "${v:1}"
    done
  } | sort -t. -k1,1nr -k2,2nr -u
}

php_is_system() { [[ $1 == "$(php_system_version)" ]]; }

# php_bin VERSION — the CLI binary for VERSION.
php_bin() {
  if php_is_system "$1"; then printf '/usr/bin/php\n'; else printf '/usr/bin/php%s\n' "${1//./}"; fi
}

# php_fpm_socket VERSION / php_fpm_unit VERSION / php_helper_arg VERSION ("" for system).
php_fpm_socket() {
  if php_is_system "$1"; then printf '/run/php-fpm/devctl.sock\n'; else printf '/var/opt/remi/php%s/run/php-fpm/devctl.sock\n' "${1//./}"; fi
}
php_fpm_unit() {
  if php_is_system "$1"; then printf 'php-fpm.service\n'; else printf 'php%s-php-fpm.service\n' "${1//./}"; fi
}
php_helper_arg() { php_is_system "$1" || printf '%s\n' "$1"; }

# php_fpm_ready VERSION — devctl's pool exists for VERSION.
php_fpm_ready() {
  local pool=/etc/php-fpm.d/devctl.conf
  php_is_system "$1" || pool="/etc/opt/remi/php${1//./}/php-fpm.d/devctl.conf"
  grep -qs 'Managed by devctl' "$pool"
}

# php_run VERSION ARGS... — run PHP VERSION (e.g. php_run 8.4 artisan migrate).
php_run() {
  local bin
  bin=$(php_bin "$1")
  shift
  [[ -x $bin ]] || die "$EX_PRECONDITION" "PHP is not installed at $bin (devctl runtime php add VERSION)"
  "$bin" "$@"
}

# php_composer VERSION ARGS... — Composer running on PHP VERSION.
php_composer() {
  local v=$1
  shift
  php_run "$v" "$(command -v composer)" "$@"
}

# php_choose_for PATH — the newest installed PHP the project accepts (composer.lock platform
# requirements: PHP version and extensions); prints nothing if none fits.
php_choose_for() {
  local path=$1 v
  if [[ ! -f $path/composer.lock ]]; then
    php_system_version
    return 0
  fi
  while IFS= read -r v; do
    if php_composer "$v" check-platform-reqs --lock --no-interaction --working-dir="$path" >/dev/null 2>&1; then
      printf '%s\n' "$v"
      return 0
    fi
  done < <(php_versions)
  return 0
}

# php_needed_hint PATH — why no installed PHP fits (Composer's own words), for messages.
php_needed_hint() {
  php_composer "$(php_system_version)" check-platform-reqs --lock --no-interaction --working-dir="$1" 2>&1 |
    grep -E 'failed|missing' | head -5
}
