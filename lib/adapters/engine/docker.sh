# shellcheck shell=bash
# Container engine adapter: Docker (docker-ce) with the Compose plugin.
#
# The ONLY file in devctl that runs the `docker` command. Other modules call these ce_*
# functions; a Podman adapter would implement the same functions.
#
# Docker is not started at boot (doctor/init). Whether it runs is checked with systemctl,
# never with the docker CLI: while docker.socket is active, any docker command would start
# the daemon silently instead of through devctl.

# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

CE_START_TIMEOUT=30 # seconds; not readonly so tests can shorten it

ce_name() { printf 'docker\n'; }

ce_cli_available() { command -v docker >/dev/null; }

ce_daemon_running() { systemctl is-active --quiet docker.service; }

ce_daemon_enabled_at_boot() {
  local unit
  for unit in docker.service docker.socket; do
    [[ $(systemctl is-enabled "$unit" 2>/dev/null) == enabled ]] && return 0
  done
  return 1
}

ce_version() {
  ce_cli_available || return 1
  docker version --format '{{.Client.Version}}' 2>/dev/null
}

# ce_ensure_running — start Docker through the privileged helper if it is not running,
# then wait until it answers.
ce_ensure_running() {
  ce_cli_available || die "$EX_PRECONDITION" "docker is not installed"
  ce_daemon_running && return 0
  ui_step "Docker is not running; starting it (needs your password)"
  priv_run --desc "Start Docker" docker-start || die "$EX_EXTERNAL" "could not start Docker"
  ((DEVCTL_DRY_RUN)) && return 0
  local i
  for ((i = 0; i < CE_START_TIMEOUT * 2; i++)); do
    if ce_daemon_running && docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
      ui_ok "Docker is running"
      return 0
    fi
    sleep 0.5
  done
  die "$EX_EXTERNAL" "Docker did not become ready within ${CE_START_TIMEOUT}s; see: journalctl -u docker -n 30"
}

ce_daemon_stop() {
  ce_daemon_running || return 0
  priv_run --desc "Stop Docker" docker-stop
}

# ---- containers (Docker must be running) ------------------------------------------------

# ce_managed_containers — devctl's containers: NAME<TAB>STATE<TAB>IMAGE
ce_managed_containers() {
  docker ps -a --filter label=devctl.managed=true --format '{{.Names}}\t{{.State}}\t{{.Image}}'
}

# ce_running_count — number of running containers (devctl's or not).
ce_running_count() {
  docker ps -q | wc -l
}

# ce_status NAME — running | exited | restarting | created | paused | dead | missing
ce_status() {
  local state
  # For an unknown name docker prints an empty line before failing: never pass that on.
  state=$(docker inspect --format '{{.State.Status}}' -- "$1" 2>/dev/null) || state=""
  printf '%s\n' "${state:-missing}"
}

# ce_restart_info NAME — "RESTART_COUNT EXIT_CODE"
ce_restart_info() {
  docker inspect --format '{{.RestartCount}} {{.State.ExitCode}}' -- "$1" 2>/dev/null
}

# ce_up PROJECT COMPOSE_FILE — create/start a stack and wait for its healthchecks.
ce_up() {
  run_change --desc "Start $1" -- docker compose --project-name "$1" --file "$2" up --detach --wait
}

# ce_down PROJECT COMPOSE_FILE — stop and remove the stack's containers. Volumes and data
# folders are always kept (no --volumes).
ce_down() {
  run_change --desc "Stop $1" -- docker compose --project-name "$1" --file "$2" down
}

# ce_exec [--env NAME]... CONTAINER -- COMMAND [ARGS...] — run inside a container; stdin is
# passed through. --env NAME copies the variable NAME from devctl's environment into the
# container *by name*: its value never appears on a command line (visible to all users).
ce_exec() { ce__exec --interactive "$@"; }

# ce_exec_tty — same, with a terminal (interactive shells).
ce_exec_tty() { ce__exec --interactive --tty "$@"; }

ce__exec() {
  local -a opts=()
  while [[ $1 == --interactive || $1 == --tty ]]; do
    opts+=("$1")
    shift
  done
  while [[ ${1:-} == --env ]]; do
    [[ $2 =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "$EX_FAIL" "ce_exec: bad variable name (bug)"
    opts+=(--env "$2")
    shift 2
  done
  local name=$1
  shift
  [[ ${1:-} == -- ]] && shift
  docker exec "${opts[@]}" -- "$name" "$@"
}

# ce_logs NAME [--follow] [--since DURATION]
ce_logs() {
  local name=$1
  shift
  docker logs "$@" -- "$name"
}

# ce_network_ensure NAME — create a user-defined bridge network if missing.
ce_network_ensure() {
  docker network inspect -- "$1" >/dev/null 2>&1 && return 0
  run_change --desc "Create network $1" -- docker network create --label devctl.managed=true -- "$1"
}

ce_pull() {
  run_change --desc "Download image" -- docker pull --quiet -- "$1"
}

# ce_compose_purge PROJECT COMPOSE_FILE — remove a stack INCLUDING its named volumes.
# Destroys data: only for explicit, typed-confirmed commands (db legacy-remove).
ce_compose_purge() {
  run_change --desc "Remove $1 with its volumes" -- docker compose --project-name "$1" --file "$2" down --volumes
}

# ---- images (update checks) ---------------------------------------------------------------

# ce_image_local_digest IMAGE — digest of the image as pulled (manifest list), or nothing.
ce_image_local_digest() {
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' -- "$1" 2>/dev/null |
    sed -n 's/^[^@]*@//p' | head -1
}

# ce_image_remote_digest IMAGE — current digest of the tag in the registry (network).
ce_image_remote_digest() {
  timeout 30 docker buildx imagetools inspect --format '{{json .Manifest.Digest}}' -- "$1" 2>/dev/null | tr -d '"'
}

# ce_crashed — devctl's containers that stopped with an error after their restarts:
# NAME<TAB>EXIT_CODE<TAB>RESTARTS<TAB>FINISHED_AT
ce_crashed() {
  local name
  docker ps -a --filter label=devctl.managed=true --filter status=exited --format '{{.Names}}' 2>/dev/null |
    while IFS= read -r name; do
      docker inspect --format '{{.Name}}{{"\t"}}{{.State.ExitCode}}{{"\t"}}{{.RestartCount}}{{"\t"}}{{.State.FinishedAt}}' -- "$name" 2>/dev/null
    done | sed 's#^/##' | awk -F'\t' '$2 != 0'
}
