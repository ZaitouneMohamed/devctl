# shellcheck shell=bash
# summary: Language runtimes: PHP-FPM, Node (fnm), Java (JDK), Python (uv)

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action runtime.setup runtime.php

# shellcheck source=lib/services/php.sh
source "$DEVCTL_ROOT/lib/services/php.sh"

# fnm is not packaged by Fedora. Pinned version + SHA-256 (from the GitHub release's asset
# digest, checked 2026-11-05): updating fnm is a reviewed code change, never "latest".
readonly FNM_VERSION=1.39.0
readonly FNM_SHA256=7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224
readonly FNM_URL="https://github.com/Schniz/fnm/releases/download/v$FNM_VERSION/fnm-linux.zip"
readonly FNM_BIN="$HOME/.local/bin/fnm"
readonly RT_SHELL_FILE="$HOME/.bashrc.d/devctl.sh"
readonly RT_FPM_POOL=/etc/php-fpm.d/devctl.conf
readonly RT_FPM_SOCKET=/run/php-fpm/devctl.sock
readonly RT_RUNTIMES=(php node java python)

# ---- state --------------------------------------------------------------------------------

# PHP extensions Laravel projects commonly need that Fedora ships as separate packages.
rt_php_missing_extensions() {
  php -m 2>/dev/null | grep -qix sodium || echo php-sodium
}

rt_php_state() {
  if [[ ! -x /usr/sbin/php-fpm ]]; then echo missing
  elif [[ -n $(rt_php_missing_extensions) ]]; then echo "extensions missing: $(rt_php_missing_extensions | paste -sd' ')"
  elif ! grep -qs 'Managed by devctl' "$RT_FPM_POOL"; then echo "no devctl pool"
  elif ! grep -qs 'error_log\] = syslog' "$RT_FPM_POOL"; then echo "pool outdated"
  else echo ok
  fi
}
rt_node_state() {
  [[ -x $FNM_BIN ]] || { echo missing; return; }
  "$FNM_BIN" ls 2>/dev/null | grep -q "v$(config_get runtime.node_default)\." && echo ok || echo "node $(config_get runtime.node_default) missing"
}
rt_java_state() { command -v javac >/dev/null && echo ok || echo "JDK missing"; }
rt_python_state() { command -v uv >/dev/null && echo ok || echo "uv missing"; }
rt_shell_state() { grep -qs 'Managed by devctl' "$RT_SHELL_FILE" && echo ok || echo missing; }

rt__version() { # RUNTIME → installed version text
  case $1 in
    php) command -v php >/dev/null && php -r 'echo PHP_VERSION;' 2>/dev/null ;;
    node) [[ -x $FNM_BIN ]] && "$FNM_BIN" exec --using=default node -v 2>/dev/null ;;
    java) command -v javac >/dev/null && javac -version 2>&1 | awk '{print $2}' ;;
    python) command -v python3 >/dev/null && python3 -c 'import platform; print(platform.python_version())' 2>/dev/null ;;
  esac
}

cmd_runtime() { cmd_runtime_status "$@"; }

cmd_runtime_status() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl runtime status"
  local rt
  if ((DEVCTL_JSON)); then
    local -a rows=()
    for rt in "${RT_RUNTIMES[@]}"; do rows+=("$rt" "$("rt_${rt}_state")" "$(rt__version "$rt" || true)"); done
    jq -n --argjson r "$(json_array "${rows[@]}")" --arg shell "$(rt_shell_state)" \
      '{runtimes: [range(0; $r | length; 3) as $i | {name: $r[$i], state: $r[$i + 1], version: $r[$i + 2]}], shell: $shell}'
    return 0
  fi
  {
    printf 'RUNTIME\tSTATE\tVERSION\tDETAILS\n'
    printf 'php\t%s\t%s\tPHP-FPM pool runs as you; socket %s\n' "$(rt_php_state)" "$(rt__version php)" "$RT_FPM_SOCKET"
    printf 'node\t%s\t%s\tfnm %s; default Node %s; .nvmrc/.node-version per project\n' "$(rt_node_state)" "$(rt__version node || echo -)" "$FNM_VERSION" "$(config_get runtime.node_default)"
    printf 'java\t%s\t%s\tFedora OpenJDK; .java-version per project\n' "$(rt_java_state)" "$(rt__version java || echo -)"
    printf 'python\t%s\t%s\tuv; .python-version per project\n' "$(rt_python_state)" "$(rt__version python)"
    printf 'shell\t%s\t-\t%s (fnm on cd, NODE_EXTRA_CA_CERTS)\n' "$(rt_shell_state)" "${RT_SHELL_FILE/#$HOME/\~}"
  } | ui_table
}

# ---- setup --------------------------------------------------------------------------------

cmd_runtime_setup() {
  local -a want=() packages=() plan=()
  local rt
  (($#)) || set -- all
  for rt; do
    case $rt in
      all) want=("${RT_RUNTIMES[@]}") ;;
      php | node | java | python) is_in_list "$rt" "${want[@]}" || want+=("$rt") ;;
      *) die "$EX_USAGE" "usage: devctl runtime setup [all|php|node|java|python]..." ;;
    esac
  done

  for rt in "${want[@]}"; do
    case $rt:$("rt_${rt}_state") in
      *:ok) ;;
      php:missing) packages+=(php-fpm); mapfile -t -O "${#packages[@]}" packages < <(rt_php_missing_extensions)
        plan+=("PHP: install php-fpm (+ extensions Laravel packages need), add devctl's pool (runs as you)") ;;
      php:"extensions missing"*) mapfile -t -O "${#packages[@]}" packages < <(rt_php_missing_extensions)
        plan+=("PHP: install missing extensions: $(rt_php_missing_extensions | paste -sd' ')") ;;
      php:*) plan+=("PHP: add devctl's PHP-FPM pool (runs as you)") ;;
      node:missing) plan+=("Node: download fnm $FNM_VERSION (checksum verified) to ~/.local/bin, install Node $(config_get runtime.node_default) as default") ;;
      node:*) plan+=("Node: install Node $(config_get runtime.node_default) with fnm, as default") ;;
      java:*) packages+=(java-25-openjdk-devel); plan+=("Java: install the JDK (java-25-openjdk-devel)") ;;
      python:*) packages+=(uv); plan+=("Python: install uv") ;;
    esac
  done
  if is_in_list node "${want[@]}" && [[ $(rt_shell_state) != ok ]]; then
    plan+=("Shell: create ${RT_SHELL_FILE/#$HOME/\~} (fnm switches Node per project on cd; Node trusts local HTTPS)")
  fi
  if ((${#plan[@]} == 0)); then
    ui_skip "runtimes are set up"
    return 0
  fi
  ui_header "Runtime setup"
  printf '  - %s\n' "${plan[@]}"
  ((${#packages[@]})) && ui_note "Fedora packages (sudo): ${packages[*]} — this cancels updates GNOME Software scheduled for reboot (it schedules them again)"
  confirm_or_abort "Do this now?"

  if ((${#packages[@]})); then
    priv_run --desc "Install packages" pkg-install "${packages[@]}" || die "$EX_EXTERNAL" "package installation failed"
  fi
  if is_in_list php "${want[@]}" && [[ $(rt_php_state) != ok && $(rt_php_state) != "extensions missing"* ]]; then
    priv_run --desc "Add devctl's PHP-FPM pool" php-fpm-setup || die "$EX_EXTERNAL" "PHP-FPM pool setup failed"
  fi
  if is_in_list node "${want[@]}"; then
    [[ -x $FNM_BIN ]] || rt__install_fnm
    [[ $(rt_node_state) == ok ]] || rt__install_node
    [[ $(rt_shell_state) == ok ]] || rt__write_shell_file
  fi
  ((DEVCTL_DRY_RUN)) && return 0
  cmd_runtime_status
}

# Download into a private temporary folder, verify the checksum, then install the binary.
rt__install_fnm() {
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "download $FNM_URL, verify sha256 $FNM_SHA256, install to $FNM_BIN"
    return 0
  fi
  local dir sum
  make_temp_dir dir
  ui_step "Downloading fnm $FNM_VERSION"
  curl -fsSL --proto '=https' --max-time 120 -o "$dir/fnm.zip" -- "$FNM_URL" || die "$EX_EXTERNAL" "download failed: $FNM_URL"
  sum=$(sha256sum -- "$dir/fnm.zip" | cut -d' ' -f1)
  [[ $sum == "$FNM_SHA256" ]] || die "$EX_EXTERNAL" "fnm download checksum mismatch (got $sum); nothing installed"
  unzip -q -o -- "$dir/fnm.zip" fnm -d "$dir/out" || die "$EX_EXTERNAL" "could not unpack fnm"
  ensure_private_dir "${FNM_BIN%/*}"
  run_change --desc "Install fnm" -- install -m 0755 -T -- "$dir/out/fnm" "$FNM_BIN" || die "$EX_EXTERNAL" "could not install fnm"
  ui_ok "fnm $("$FNM_BIN" --version | awk '{print $2}') installed (checksum verified)"
}

rt__install_node() {
  local v
  v=$(config_get runtime.node_default)
  run_change --desc "Install Node $v" -- "$FNM_BIN" install "$v" || die "$EX_EXTERNAL" "fnm could not install Node $v"
  run_change --desc "Make Node $v the default" -- "$FNM_BIN" default "$v" || die "$EX_EXTERNAL" "fnm could not set the default"
}

# A devctl-owned file in ~/.bashrc.d (Fedora's ~/.bashrc sources that folder).
rt__write_shell_file() {
  if ((DEVCTL_DRY_RUN)); then
    ui_plan "write $RT_SHELL_FILE"
    return 0
  fi
  if [[ -e $RT_SHELL_FILE ]] && ! grep -qs 'Managed by devctl' "$RT_SHELL_FILE"; then
    die "$EX_CONFLICT" "$RT_SHELL_FILE exists and was not written by devctl; not touching it"
  fi
  grep -q 'bashrc.d' "$HOME/.bashrc" 2>/dev/null ||
    ui_note "your ~/.bashrc does not read ~/.bashrc.d; add: for rc in ~/.bashrc.d/*; do . \"\$rc\"; done"
  ensure_private_dir "${RT_SHELL_FILE%/*}"
  cat >"$RT_SHELL_FILE" <<'SHELL'
# Managed by devctl (devctl runtime setup). Changes are overwritten.
# Node: fnm switches version on cd, from .nvmrc / .node-version (or the default).
if [ -x "$HOME/.local/bin/fnm" ]; then
  eval "$("$HOME/.local/bin/fnm" env --use-on-cd --version-file-strategy=recursive --shell bash)"
fi
# Node does not use the system certificate store: trust devctl's local HTTPS explicitly.
if [ -f "$HOME/.local/share/devctl/ca/root.crt" ]; then
  export NODE_EXTRA_CA_CERTS="$HOME/.local/share/devctl/ca/root.crt"
fi
SHELL
  chmod 600 -- "$RT_SHELL_FILE"
  ui_ok "Shell integration written (open a new terminal)"
}

# php [list] | php add VERSION — other PHP versions side by side (Remi, ADR-0020).
cmd_runtime_php() {
  local sub=${1:-list}
  case $sub in
    list)
      local v sys
      sys=$(php_system_version)
      {
        printf 'PHP\tSOURCE\tDEVCTL POOL\tCLI\n'
        while IFS= read -r v; do
          printf '%s\t%s\t%s\t%s\n' "$v" "$([[ $v == "$sys" ]] && echo "Fedora (default)" || echo Remi)" \
            "$(php_fpm_ready "$v" && echo yes || echo no)" "$(php_bin "$v")"
        done < <(php_versions)
      } | ui_table
      ;;
    add)
      local v=${2:-}
      [[ $v =~ ^8\.[1-4]$ ]] || die "$EX_USAGE" "usage: devctl runtime php add 8.1|8.2|8.3|8.4"
      if php_is_system "$v"; then ui_skip "PHP $v is Fedora's PHP (devctl runtime setup php)"; return 0; fi
      if [[ -x $(php_bin "$v") ]] && php_fpm_ready "$v"; then ui_skip "PHP $v is already set up"; return 0; fi
      ui_header "Add PHP $v next to PHP $(php_system_version)"
      if ! rpm -q remi-release >/dev/null 2>&1; then
        printf '  %s\n' "adds the Remi repository (third-party, rpms.remirepo.net — Fedora's well-known PHP packager):" \
          "    release package checked against a pinned SHA-256, signing key against Remi's published fingerprint"
      fi
      printf '  %s\n' "installs php${v//./}-php-* (CLI, FPM and the extensions Laravel needs) from Remi" \
        "labels it for SELinux so its PHP-FPM is confined like Fedora's; adds devctl's pool (runs as you)" \
        "your default php stays $(php_system_version); this one is $(php_bin "$v")"
      confirm_or_abort "Do this now? (administrator password asked)"
      if ! rpm -q remi-release >/dev/null 2>&1; then
        priv_run --desc "Enable the Remi repository (verified)" remi-enable || die "$EX_EXTERNAL" "could not enable Remi"
      fi
      priv_run --desc "Install PHP $v" php-version-install "$v" || die "$EX_EXTERNAL" "could not install PHP $v"
      priv_run --desc "Add devctl's PHP-FPM $v pool" php-fpm-setup "$v" || die "$EX_EXTERNAL" "could not set up the PHP-FPM $v pool"
      ((DEVCTL_DRY_RUN)) || ui_ok "PHP $v is ready. Use it for a site: devctl site php NAME $v"
      ;;
    *) die "$EX_USAGE" "usage: devctl runtime php [list] | devctl runtime php add VERSION" ;;
  esac
}

complete_runtime() {
  if [[ $1 == args && $2 == php ]]; then
    [[ $3 == 1 ]] && printf '%s\n' list add
    [[ $3 == 2 ]] && printf '%s\n' 8.4 8.3 8.2 8.1
    return 0
  fi
  [[ $1 == args && $2 == setup ]] && printf '%s\n' all "${RT_RUNTIMES[@]}"
  return 0
}

help_runtime() {
  cat <<'HELP'
Usage: devctl runtime [status]                         versions and state
       devctl runtime setup [all|php|node|java|python]  install what is missing (asks first)
       devctl runtime php [list]                        PHP versions installed
       devctl runtime php add VERSION                   another PHP version side by side (Remi)

PHP     Fedora php-fpm; devctl's pool runs as you (socket /run/php-fpm/devctl.sock, only
        Caddy may connect), confined by SELinux. Other PHP versions: Remi (asked when needed).
Node    fnm (pinned, checksum-verified) in ~/.local/bin; default Node from runtime.node_default;
        per project: .nvmrc or .node-version. Shell hook: ~/.bashrc.d/devctl.sh
Java    Fedora OpenJDK JDK; per project: .java-version
Python  uv; per project: .python-version / pyproject.toml
HELP
}
