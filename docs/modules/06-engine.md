# Module 6 — Container engine adapter

Status: built and tested · 2026-11-05 · implements [ADR-0006](../decisions/0006-adapter-layer-for-every-external-system.md)

## Purpose
One file runs `docker`; everything else calls `ce_*` functions. Docker starts on demand
(it no longer starts at boot) through the privileged helper.

## Pieces
| Piece | Where |
|---|---|
| Adapter loader `adapter_load KIND` (setting `KIND.adapter`) | `lib/core/adapter.sh` |
| Docker adapter | `lib/adapters/engine/docker.sh` |
| `devctl engine [status\|start\|stop]` | `lib/cmd/engine.sh` — [docs](../commands/engine.md) |
| Helper verbs `docker-start`, `docker-stop` (helper version 3) | `libexec/devctl-root` |
| Setting `engine.adapter = docker` | `share/defaults.conf` |

## Adapter interface (what a Podman adapter would implement)
`ce_name`, `ce_cli_available`, `ce_version`, `ce_daemon_running`, `ce_daemon_enabled_at_boot`,
`ce_ensure_running`, `ce_daemon_stop`, `ce_managed_containers`, `ce_running_count`,
`ce_status NAME`, `ce_restart_info NAME`, `ce_up PROJECT FILE`, `ce_down PROJECT FILE`,
`ce_exec NAME -- CMD…`, `ce_exec_tty NAME -- CMD…`, `ce_logs NAME [opts]`,
`ce_network_ensure NAME`, `ce_pull IMAGE`.

## Decisions inside the module
- **Is Docker running?** asked with `systemctl is-active docker.service`, never the docker
  CLI: docker.service is socket-activated, so a CLI call would start it silently.
- **Stop** stops `docker.socket` and `docker.service` for the same reason.
- **Start** waits until `docker info` answers (up to 30 s), then continues.
- **`ce_down` never passes `--volumes`**: data is only removed by explicit, typed-confirmed commands.
- **devctl's containers** carry the label `devctl.managed=true` (set by module 7's templates).
- Note: being in the `docker` group is root-equivalent; that was your existing setup and the
  reason devctl keeps every published port on 127.0.0.1.

## Edge cases
| Case | Behavior |
|---|---|
| Docker not installed | exit 7 "docker is not installed" |
| Not running when a command needs it | started via helper (sudo password), then waits |
| Never becomes ready | exit 9 with `journalctl -u docker -n 30` |
| Stop with running containers | asks first (they will stop) |
| `--dry-run` with an outdated helper | plan still shown, plus a note (fixed in `priv_run`) |

## Tests
11 new bats tests (`tests/unit/engine.bats`) with fake `docker`/`systemctl`: adapter
selection, systemctl-only running check, start + wait, timeout, idempotent start, exact
compose commands (no `--volumes`), missing container, argv passing, CLI status/stop, dry-run
with outdated helper, helper verb arguments. `make check`: lint + 137 bats + 23 Python — pass.
Real check: `devctl engine status` on this laptop → docker 29.9.2, running, not at boot.
