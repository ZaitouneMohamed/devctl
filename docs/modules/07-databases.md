# Module 7 — Databases

Status: built and tested (unit + real Docker) · 2026-11-05 · implements ADR-0007, ADR-0008, ADR-0016

## Engines (templates/engines/<engine>/)
| Engine | Image (verified on Docker Hub 2026-11-05) | Default port | Users per project |
|---|---|---|---|
| mysql | `mysql:8.4` (LTS; 9.7 available) | 3306 | yes |
| mariadb | `mariadb:11.8` (LTS) | 3406 | yes |
| postgres | `pgvector/pgvector:pg18` (PostgreSQL 18 + pgvector) | 5432 | yes, pgvector enabled per database |
| mongodb | `mongo:8.0` | 27017 | yes (readWrite + dbAdmin on its database) |
| qdrant | `qdrant/qdrant:v1.20` | 6333 (+ /dashboard) | no: shared API key, collections per project |
| redis | `redis:8.8` | 6379 | no: cache only, no persistence, prefix per project |
| sqlite | — (file in the project) | — | — |

Each engine = `engine.conf` (settings) + `compose.yaml.tmpl` + `driver.sh` (create, is_empty,
shell, root_shell, dump, restore). Adding an engine = adding a folder.

## Servers
- One shared server per engine + major (`mysql-8-4`, `postgres-18`, …); container
  `devctl-<id>`, compose project the same, network `devctl`, label `devctl.managed=true`.
- **Ports**: allocated once from the engine's default, recorded in `registry/ports.tsv`, never
  reused or changed. If the default port is busy, `db add` refuses (so you can free it, e.g.
  `devctl db legacy-remove`) unless you pass `--any-port`.
- **Data**: `~/.local/share/devctl/data/<id>` (inside the No-CoW subvolume), mode 0711 so the
  database's own user can pass through; `data/` stays 0700. Bind mounts, no Docker volumes.
- **Secrets**: root `secrets/servers/<id>.env`, per database `secrets/databases/<server>/<db>.env`
  (0600, 32-char letters+digits). Root work inside containers uses the container's own env
  variable; user passwords are passed into `docker exec` by variable name, never on a command line.
- **Restart policy** `on-failure:3`; json-file logs 10 MB × 3; healthchecks; `up --wait`.
- **On demand**: `db_server_acquire`/`db_server_release` count users (sites, module 11);
  the server stops when the count reaches 0. `db stop` refuses while used (or `--force`).
- **Memory guard** before starting a heavy engine (< 25 % RAM available → asks).

## Commands — [docs](../commands/db.md)
`db [list] [--databases]`, `engines`, `add`, `create`, `creds`, `shell`, `root`, `start`,
`stop`, `export`, `import`, `legacy-remove`.

## Known limitations
- **MongoDB**: its tools only take passwords as arguments, so during a Mongo command the
  password is briefly visible in the process list to other local accounts (single-user laptop).
- **Qdrant**: no per-project users (shared API key).
- **Docker runs without SELinux support** (docker-ce default: `selinux-enabled` is false), so
  `:Z` is ignored and containers are not SELinux-confined. Turning it on is a separate,
  deliberate change (planned as a doctor check).
- MariaDB, MongoDB and Qdrant drivers are unit-tested but not yet run against real containers
  (their images are not downloaded); `make itest` covers MySQL, PostgreSQL+pgvector, Redis.

## Bugs found by the real-Docker tests (fixed)
- PostgreSQL 18 could not start: the entrypoint switches to user `postgres`, which could not
  pass through a 0700 mount → data folders are 0711, mount `/var/lib/postgresql`.
- Mounting only `<major>/docker` left an anonymous Docker volume per start → mount the parent.
- `pg_restore` as the project user failed on `COMMENT ON EXTENSION vector` → extension entries
  are skipped (pgvector is already enabled by `db create`).
- `db stop` ignored exited/unhealthy containers (left them behind) → removes any state.
- `ce_status` returned an empty line + "missing" for unknown containers → fixed.
- `dry-run` plan text mixed into a captured server id → plan lines to stderr there.

## Tests
- Unit: 13 bats tests (`tests/unit/db.bats`): templates complete, registration, fixed and
  never-reused ports, busy-port refusal, versions, Redis without data/secrets, rendering,
  names, resolution, secrets, memory guard, SQL text without secrets in arguments, CLI paths,
  legacy-remove confirmation.
- Integration: `make itest` (5 tests, real Docker, isolated HOME + `devctl-itest-*`): MySQL
  user isolation/export/import/typed confirm/bind mount; PostgreSQL ownership, pgvector,
  export/import, single mount; Redis no persistence; list; refcount. All pass; nothing left behind.
- `make check`: lint + 150 bats + 23 Python — all pass.
