# devctl — Architecture

Status: **Approved 2026-11-05** (living document; changes recorded as ADRs).
Requirements: [REQUIREMENTS.md](REQUIREMENTS.md). Decisions: [decisions/](decisions/) (ADR-NNNN referenced inline).

---

## 1. System overview

```
                         ┌────────────────────────── user ──────────────────────────┐
                         │  terminal: devctl …            browser: https://devctl.test │
                         └───────────┬───────────────────────────────┬──────────────┘
                                     │                               │ (127.0.0.1 only)
                                     ▼                               ▼
   ┌────────────────────────────────────────────┐      ┌──────────────────────────────┐
   │ devctl (Bash)  — single source of truth     │◄─────│ dashboard (Python stdlib)     │
   │  bin/devctl → router → lib/cmd/*            │ exec │  SSE live view, SQLite index  │
   │  core: log, config, validate, ui, history   │      │  of history; never acts alone │
   │  adapters: engine, web, dns, runtime, …     │      └──────────────────────────────┘
   └──────┬──────────────┬───────────────┬──────┘
          │ sudo / pkexec│               │ docker CLI (via engine adapter)
          ▼              │               ▼
   ┌───────────────┐     │       ┌──────────────────────────────────────────┐
   │ devctl-root   │     │       │ Docker (not enabled at boot)              │
   │ privileged    │     │       │  devctl-mysql-8.4  127.0.0.1:3306          │
   │ helper:       │     │       │  devctl-postgres-18 127.0.0.1:5432  …      │
   │ hosts block,  │     │       │  data: ~/.local/share/devctl/data (+C)    │
   │ caddy sites,  │     │       └──────────────────────────────────────────┘
   │ selinux, fpm, │     │
   │ docker start  │     ▼  host runtimes (user)
   └──────┬────────┘   PHP-FPM pools (one per PHP version, run as user), Node (fnm),
          ▼            Java (OpenJDK side by side), Python (uv), Ollama
   ┌───────────────────────────┐
   │ Caddy (system service)     │  :80/:443 → name.test → php_fastcgi unix socket
   │ local CA, per-site files   │                         reverse_proxy 127.0.0.1:PORT
   └───────────────────────────┘                         file_server (static)
```

Principles:
1. **CLI is the only actor.** The dashboard, git hooks and the background timer all call `devctl`. (ADR-0009)
2. **One privileged entry point.** Everything needing root goes through `devctl-root` — a small, separately installed, input-validating script invoked with `sudo` (CLI) or `pkexec` (dashboard). (ADR-0019)
3. **Adapters at every boundary.** Container engine, web server, hosts/DNS, runtime managers, DB engines, tunnels, notifications. Core code never calls `docker`, `caddy` or `/etc/hosts` directly. (ADR-0006)
4. **Declarative state + idempotent apply.** Registry files describe what should exist; commands plan, show, confirm, apply. `--dry-run` prints the plan only.
5. **Nothing runs unless asked**, except the background check timer (ADR-0010).

## 2. Repository layout (Bash project structure)

```
devctl/
├── bin/devctl                     # entry: strict mode, locate lib, source core, route
├── lib/
│   ├── core/                      # no knowledge of Docker/Caddy/etc.
│   │   ├── bootstrap.sh           # strict mode, traps, paths, DEVCTL_* globals
│   │   ├── log.sh                 # log_debug/info/warn/error → stderr + daily file
│   │   ├── ui.sh                  # colors, confirm(), confirm_typed(), spinner, tables
│   │   ├── errors.sh              # die(), exit codes, ERR trap with stack trace
│   │   ├── config.sh              # safe key=value parser, defaults < file < env < flags
│   │   ├── validate.sh            # is_domain_label, is_port, is_semver, is_engine, …
│   │   ├── registry.sh            # sites/servers/ports registry read/write (atomic, flock)
│   │   ├── history.sh             # append JSONL action/alert records
│   │   ├── lock.sh                # flock-based mutual exclusion
│   │   ├── run.sh                 # run/plan wrapper: honors --dry-run, logs, records history
│   │   ├── guard.sh               # memory guard, disk guard
│   │   ├── notify.sh              # notify-send wrapper
│   │   └── privilege.sh           # calls devctl-root via sudo/pkexec, never builds strings
│   ├── adapters/
│   │   ├── engine/docker.sh       # ce_up, ce_down, ce_exec, ce_logs, ce_ps, ce_inspect, ce_pull …
│   │   ├── web/caddy.sh           # web_render_site, web_apply, web_validate, web_rollback
│   │   ├── dns/hosts.sh           # dns_add, dns_remove, dns_list (block in /etc/hosts)
│   │   ├── runtime/{php,node,java,python}.sh   # rt_detect_version, rt_ensure, rt_env
│   │   ├── tls/{nss,system,node,java}.sh       # trust_check, trust_install
│   │   ├── vcs/github.sh          # clone via gh or git
│   │   └── tunnel/                # PARKED (sharing)
│   ├── cmd/                       # one file per top-level command; thin, call services
│   │   ├── site.sh  domain.sh  db.sh  svc.sh  logs.sh  status.sh  ai.sh  cloud.sh
│   │   ├── doctor.sh  init.sh  dashboard.sh  history.sh  menu.sh  hook.sh  help.sh
│   └── services/                  # business logic shared by cmd/ and dashboard calls
│       ├── projects.sh  dbservers.sh  refcount.sh  ports.sh  selinux.sh  templates.sh
├── libexec/devctl-root            # privileged helper (installed root-owned to /usr/local/libexec)
├── templates/
│   ├── projects/laravel-inertia-react/   # template.conf + hooks/{create,post-clone}.sh + files/
│   ├── engines/{mysql,mariadb,postgres,mongodb,qdrant,redis,sqlite}/   # engine.conf + compose.tmpl + init/
│   ├── services/{mailpit,meilisearch,elasticsearch,objectstore,rabbitmq,kafka,ollama}/
│   ├── caddy/{php,static,proxy,vite}.caddy.tmpl
│   └── fpm/pool.conf.tmpl
├── dashboard/                     # Python, stdlib only (http.server, sqlite3, subprocess)
│   ├── devctl_dash/{server,api,events,history,auth}.py
│   └── static/{index.html,app.js,app.css}
├── share/
│   ├── defaults.conf              # every config key with default + comment
│   ├── completions/devctl.bash
│   ├── systemd/user/{devctl-watch.service,devctl-watch.timer,devctl-dashboard.service}
│   ├── polkit/local.devctl.root.policy
│   └── hooks/{post-merge,post-checkout}   # git hooks: notify only
├── tests/
│   ├── unit/*.bats                # core + adapters with stubbed commands (PATH shims)
│   ├── integration/*.bats         # opt-in, touches Docker (tagged, never run by default)
│   └── helpers/{common.bash,stubs/}
├── install.sh                     # user-level install: symlink bin, completion; prints next step
├── Makefile                       # lint (shellcheck), test (bats), fmt check
└── docs/  REQUIREMENTS.md  ARCHITECTURE.md  decisions/  commands/
```

Rules: `cmd/` parses flags and prints; `services/` decides; `adapters/` talk to the outside world; `core/` is generic.
Files are sourced only from the repo directory (resolved via `readlink -f` of `bin/devctl`), never from user-writable plugin paths.

### Command routing and conventions
- `devctl <noun> <verb> [args] [--flags]`; `devctl` alone → menu; `devctl help <noun>`.
- Command set: `status`, `doctor`, `init`, `dashboard`, `history`, `env`, `config`, `version`, `help`, `self`, `root`, `engine`, `site create|clone|list|start|stop|dev|set|delete`, `domain list`, `logs`, `db list|start|stop|create|shell|root|creds|import|export`, `svc list|start|stop`, `ai start|stop|list|pull|rm`, `cloud start|stop`. `site dev` runs a dev process in the foreground (ADR-0009).
- Router maps `noun` → `lib/cmd/noun.sh` → function `cmd_noun_verb`. Unknown → suggestion + exit 64.
- Global flags: `--dry-run`, `--yes` (only for non-destructive confirms; typed confirmations can't be skipped), `--json` (machine output for the dashboard), `--quiet`, `--verbose`, `--no-color`.
- Exit codes: 0 ok · 1 generic failure · 2 usage error · 3 validation error · 4 not found · 5 conflict/already exists · 6 user aborted · 7 precondition failed (guard, missing dependency) · 8 privilege denied · 9 external tool failed.

## 3. Module responsibilities (build order for Phase 2)

| # | Module | Responsibility | Depends on |
|---|---|---|---|
| 1 | core | bootstrap, log, errors, ui, config, validate, lock, run/dry-run, history | — |
| 2 | install + completion + help | `install.sh`, symlink, Tab completion, help system | 1 |
| 3 | privileged helper | `devctl-root` + install, sudo/pkexec bridge | 1 |
| 4 | doctor (read-only checks first) | all checks, fixes added as modules land | 1–3 |
| 5 | init | idempotent machine baseline (dirs, subvolume, packages, hostname, Docker-not-at-boot, timer) | 1–4 |
| 6 | engine adapter | Docker wrapper, Docker start on demand | 1,3 |
| 7 | db servers | engine templates, registry, ports, secrets, refcount, crash policy, shell/root, import/export | 6 |
| 8 | web + TLS | Caddy adapter, site templates, validate/rollback, CA trust | 3 |
| 9 | dns | hosts block via helper | 3 |
| 10 | runtimes | PHP-FPM pools, fnm, OpenJDK, uv | 3 |
| 11 | sites | create (template/clone), list, start/stop, delete, SELinux contexts, git hooks | 7–10 |
| 12 | logs + status | per-part logs, snapshot, `--watch` | 7–11 |
| 13 | services | Mailpit, Meilisearch, Elasticsearch, object storage, RabbitMQ, Kafka | 6–8 |
| 14 | background timer | disk guard, crash notify, image-update check, log pruning | 7 |
| 15 | menu | interactive Bash menu, optional fzf | 1 |
| 16 | ai | Ollama server + models | 6 |
| 17 | cloud | kind, Terraform, LocalStack adapters | 6 |
| 18 | dashboard | Python server, SSE, history index, polkit flow | all |
| — | sharing, backups | PARKED: hook points only | — |

## 4. Docker architecture

- **Engine adapter** (`lib/adapters/engine/docker.sh`) is the only file that invokes `docker`. Interface: `ce_available`, `ce_daemon_start`, `ce_up <stack>`, `ce_down <stack>`, `ce_exec <ctr> -- argv…`, `ce_logs`, `ce_status <ctr>`, `ce_pull`, `ce_image_digest`, `ce_remote_digest`, `ce_rm` (guarded). Arguments are passed as arrays, never strings. Swapping to Podman = new file implementing the same functions. (ADR-0006)
- **Stacks**: each DB server / service is a Compose project named `devctl-<server>` generated from a template into `~/.local/share/devctl/stacks/<server>/compose.yaml`. Labels: `devctl.managed=true`, `devctl.server=<id>`, `devctl.engine=<engine>`.
- **Daemon lifecycle**: `docker.service` disabled at boot (init, after asking). Any devctl command needing Docker checks `systemctl is-active docker`; if inactive → `sudo systemctl start docker` (shown, confirmed once per run). `docker.socket` stays disabled so nothing socket-activates it.
- **Networks**: one user-defined bridge `devctl` (fixed subnet from a pinned pool). `/etc/docker/daemon.json` gets `default-address-pools` limited to `172.20.0.0/14` in /24s so Docker can never allocate 192.168.x (VMware/LAN overlap). `doctor` re-checks overlaps against `ip -br addr` and VMware's `/etc/vmware/networking`.
- **Ports**: every published port binds `127.0.0.1` explicitly. Note Docker's iptables rules bypass firewalld, so loopback binding is the real protection.
- **Crash policy**: `restart: on-failure:3`. When a container is `exited` with non-zero code and restart count ≥ 3, the background timer notifies (it does not restart it again).
- **Logging**: `json-file` with `max-size=10m`, `max-file=3`.
- **Images**: pinned tags per engine major (e.g. `mysql:8.4`, `postgres:18` with pgvector image). The timer compares local vs remote digests daily (only when Docker is already running) and notifies; never pulls.

## 5. Networking, domains and proxy

- **Names**: `<label>.test` (suffix configurable). Label validation: `^[a-z][a-z0-9-]{0,40}[a-z0-9]$`, unique across registry and existing hosts block; reserved: `devctl`, `mail`, `localhost`, `www`.
- **Resolution**: managed block in `/etc/hosts`:
  ```
  # >>> devctl managed block — do not edit by hand >>>
  127.0.0.1 shop.test
  ::1       shop.test
  # <<< devctl managed block <<<
  ```
  `devctl-root hosts-apply <file>`: validates every line against the strict pattern, rewrites only the block via temp file + `rename`, keeps `/etc/hosts.devctl.bak`, restores SELinux label (`restorecon`). No dnsmasq/wildcard DNS: explicit entries are simpler and need no resolver changes. (ADR-0004)
- **Caddy** (Fedora package, 2.10.2 in updates) runs as the system service. `/etc/caddy/Caddyfile` contains a global block + `import /etc/caddy/devctl/*.caddy`. Per-site files are rendered as the user into `~/.local/share/devctl/caddy/pending/`, then `devctl-root caddy-apply`: copy to staging → `caddy validate` on the full config → swap into `/etc/caddy/devctl/` → `systemctl reload caddy` → on failure restore `/etc/caddy/devctl.last-good/` and reload. (ADR-0003)
  - Admin API bound to a unix socket only (no `localhost:2019` TCP), so other local processes cannot reconfigure it.
  - Site kinds: `php` (root `public/`, `php_fastcgi unix//run/devctl/php-fpm-8.5.sock`), `static` (`file_server`), `proxy` (Java/Python/Node app on 127.0.0.1:PORT; WebSockets work natively in `reverse_proxy`).
  - **Vite HMR over HTTPS** (ADR-0005): each site gets a registered Vite port `V`. Vite listens on `127.0.0.1:V+10000`; Caddy serves `https://<name>.test:V` with the site's certificate and proxies to it (incl. WebSocket). devctl writes Vite settings into an env (`VITE_DEV_SERVER_URL`/`server.origin`/`hmr.clientPort`) so `public/hot` points to `https://<name>.test:V`. No subdomains, no mixed content, no `--host`.
- **TLS / CA**: Caddy `local_certs`. Trust targets (each a small adapter with check + install):
  - system store (`/etc/pki/ca-trust/source/anchors`, `update-ca-trust`) → curl, PHP, Python, and Java (Fedora's Java cacerts is generated from the system store; verify in module 8);
  - Brave → NSS `~/.pki/nssdb` via `certutil` (needs `nss-tools`);
  - Firefox → each profile's NSS db via `certutil`, or a Firefox enterprise policy (decided in module 8);
  - Node → `NODE_EXTRA_CA_CERTS` exported by devctl's runtime env.
- **SELinux**: Caddy and the system PHP-FPM run confined as `httpd_t` (to verify on install: `ps -eZ`). devctl registers per-project rules with `semanage fcontext`: project root → `httpd_sys_content_t`; `storage/`, `bootstrap/cache/` → `httpd_sys_rw_content_t`; then `restorecon -R`. FPM sockets live in `/run/devctl/` labeled `httpd_var_run_t`. Booleans touched only if a module proves they're needed (each shown and confirmed). No `audit2allow` blanket modules.
- **Sharing** (PARKED): hook points `share.before_enable`, `share.after_disable`; a site's Caddy template already has a placeholder for an extra listener.

## 6. Database architecture

- **Engine templates** (`templates/engines/<engine>/engine.conf`): `image`, `majors`, `default_major`, `container_port`, `default_host_port`, `healthcheck`, `data_path_in_ctr`, `create_db_cmd`, `create_user_cmd`, `dump_cmd`, `restore_cmd`, `shell_cmd`, `backup_method`, `persistent=yes|no`, `heavy=yes|no`. Commands are argv arrays with `{db}`, `{user}` placeholders substituted per element (never re-parsed by a shell).
- **Servers**: id `<engine>-<major>` (shared) or `<engine>-<major>-<project>` (dedicated). Registry `~/.local/share/devctl/registry/servers.tsv`: id, engine, major, image, host_port, data_dir, created.
- **Ports**: allocated once from the engine's default upward (3306, 3307…), checked against registry + `ss -ltn`, stored forever. Never reused even after a server is removed (TablePlus connections stay valid).
- **Data**: `~/.local/share/devctl/data` is a Btrfs **subvolume** with `chattr +C` set while empty; each server dir created inside inherits No-CoW; bind-mounted with `:Z` so SELinux labels are private to that container. (ADR-0008)
- **Secrets**: `~/.local/share/devctl/secrets/` (0700); `servers/<id>.env` (root creds), `projects/<name>.env` (app user creds), all 0600. Passwords: 32 chars from `/dev/urandom` (alnum). Never echoed; `devctl db creds SITE` prints only on explicit request with a warning.
- **Per-project user**: grants limited to the project's database (MySQL/MariaDB `ALL ON db.*` without GRANT OPTION; Postgres owner of its DB, no superuser/createrole; Mongo `readWrite`+`dbAdmin` on its DB; Qdrant via collection prefix + API key note).
- **Lifecycle**: `refcount` per server in `~/.local/state/devctl/run/refcount/<id>` updated under `flock`. `site start` → for each DB server: guard memory → `ce_up` → wait healthcheck → refcount+1. `site stop` → refcount-1 → `ce_down` at 0. `db start/stop` act explicitly (with `--force` to ignore refcount).
- **SQLite**: no server; file at `database/database.sqlite` inside the project; engine template only creates it.
- **Redis**: `persistent=no` (no volume, `--save "" --appendonly no`), excluded from backups and GUI hints.
- **Import/export**: streamed through `ce_exec` (`mysqldump`, `pg_dump -Fc`, `mongodump --archive`), gzip, into a user-chosen path; import asks before overwriting a non-empty DB (typed confirmation).
- **Legacy**: the existing `dev-mysql`/`dev-postgres` are discarded after module 7 works, freeing 3306/5432 for the registry. (ADR-0016)

## 7. Runtimes

| Language | Mechanism | Pin file read | Default |
|---|---|---|---|
| PHP | Fedora `php-fpm` 8.5; older versions side by side from Remi SCL (`php84-php-fpm` …), added only after you approve the repo | `composer.json` `require.php`, `.php-version` | 8.5 |
| Node | **fnm** (single binary in `~/.local/bin`) | `.nvmrc`, `.node-version`, `package.json engines` | 26 LTS |
| Java | Fedora OpenJDK packages side by side (`java-25-openjdk-devel`, `java-21…`), per-project `JAVA_HOME` | `.java-version`, `.sdkmanrc` (read-only compatibility) | 25 LTS |
| Python | **uv** (Fedora package) | `.python-version`, `pyproject.toml` | 3.14 |

(ADR-0020, ADR-0021)

PHP-FPM: one FPM master per PHP version, system service (confined `httpd_t`), pools rendered by devctl with `user = <you>`, `listen = /run/devctl/php-fpm-<ver>.sock`, `listen.owner = caddy`. Pools are shared per version (not per site); per-site `open_basedir` is not used (dev machine).

`devctl env SITE` prints the shell environment for a site (PATH for fnm node, JAVA_HOME, NODE_EXTRA_CA_CERTS…); `devctl site start` uses it for foreground dev processes. Dashboard-started processes run as `systemd-run --user --unit=devctl-<site>-<part> --collect` with the same env (ADR-0009).

## 8. Configuration management

- Defaults: `share/defaults.conf` (in repo, documented). User overrides: `~/.config/devctl/devctl.conf`. Env: `DEVCTL_<KEY>`. Flags last.
- Format: `key = value` lines, `#` comments. Parsed by a strict reader: key must match `^[a-z][a-z0-9_.]*$`, value is literal text (no expansion, no `source`, no `eval`). Unknown keys → warning.
- Registry (machine-written state, never hand-edited): TSV files under `~/.local/share/devctl/registry/` (`sites.tsv`, `servers.tsv`, `ports.tsv`) plus one `sites/<name>.conf` per site (type, path, php version, db server, tls, compose policy, vite port). Writes are atomic (`mktemp` in same dir + `mv`) under `flock`.
- XDG layout:

| Path | Content | Mode |
|---|---|---|
| `~/.config/devctl/` | user config | 0700 |
| `~/.local/share/devctl/registry/` | registry | 0700 |
| `~/.local/share/devctl/secrets/` | credentials | 0700 / files 0600 |
| `~/.local/share/devctl/data/` | DB data (Btrfs subvol, +C) | 0700 |
| `~/.local/share/devctl/models/` | Ollama models | 0700 |
| `~/.local/share/devctl/stacks/` | generated compose files | 0700 |
| `~/.local/state/devctl/logs/` | daily logs, 7 days | 0700 |
| `~/.local/state/devctl/history.jsonl` | action/alert history | 0600 |
| `~/.local/state/devctl/run/` | refcounts, locks, pids | 0700 |
| `/etc/caddy/devctl/`, `/etc/devctl/fpm/` | rendered system config (via helper) | root |
| `/usr/local/libexec/devctl-root` | privileged helper | root 0755 |

## 9. Security model

Threat model: single user laptop on home/café/school Wi-Fi; unencrypted disk; untrusted cloned repos; browser pages that might try DNS rebinding or CSRF against local services.

- **Privilege**: no NOPASSWD. Root work only in `devctl-root`, which accepts a fixed verb list (`hosts-apply`, `caddy-apply`, `caddy-rollback`, `fpm-apply`, `selinux-context`, `docker-start`, `hostname-set`, `trust-system`, …), validates every argument (allow-list regex, paths canonicalized and confined to known prefixes), and never invokes a shell with user-supplied strings. CLI calls it with `sudo`; the dashboard with `pkexec` (polkit policy `local.devctl.root`, `auth_admin`, shows GNOME's password dialog). (ADR-0019)
- **Network exposure**: every service binds 127.0.0.1; Caddy listens on 127.0.0.1/::1 only (sharing parked). The dashboard binds 127.0.0.1 on a random high port behind Caddy at `devctl.test`.
- **Dashboard**: per-start random token (stored 0600, set as `HttpOnly; Secure; SameSite=Strict` cookie via a one-time URL opened by `devctl dashboard`), `Host` header must be `devctl.test` (anti DNS rebinding), CSRF token on every POST, CSP `default-src 'self'`. Typed confirmations enforced server-side by passing them to the CLI, which re-checks.
- **Secrets**: generated locally, 0600, never logged (log functions redact `*PASSWORD*`/`*SECRET*`/`*TOKEN*` keys), never in history args. `.env` in projects set 0600 and checked against `.gitignore`.
- **Untrusted repos**: cloning never runs repo code on its own. The one-time dependency install (`composer install`, `npm ci`) does run repo-defined scripts (Laravel needs them), so devctl shows the exact commands and asks first.
- **Input**: every user input validated in `core/validate.sh` before use; arrays for argv; `--` before positional args to external tools.
- **Findings carried by doctor**: LLMNR on 0.0.0.0:5355 (offer to disable via resolved drop-in), firewall zone open range (informational while sharing parked), disk not encrypted (informational), unknown listener 27500 (pending identification).
- **Backups/encrypted secrets folder**: PARKED; `secrets/` path is abstracted so it can later move into an encrypted, login-unlocked location.

## 10. Background checks (ADR-0010)

`devctl-watch.timer` (systemd **user** timer, enabled by `init` after asking) runs `devctl watch tick` every 30 min (`Persistent=false`, `RandomizedDelaySec=2m`):
- disk: free ≤ 20 % → notify (deduplicated, once per 6 h);
- crashes: only if Docker is already active → containers with `devctl.managed` exited non-zero after max restarts → notify + history alert;
- image updates: once per day, only if Docker is active → digest compare → notify;
- housekeeping: prune devctl logs > 7 days.
It never starts Docker or any service. Cost: one short Bash run.

## 11. Logging and history

- `log_*` → stderr (colored if TTY) and `~/.local/state/devctl/logs/devctl-YYYY-MM-DD.log` (plain, with PID and command).
- `history.sh` appends one JSON line per *action* (`ts, source=cli|dashboard|timer|hook, cmd, args (redacted), result, exit, duration`) and per *alert*. JSON produced with `jq -n --arg` (no string concatenation). The dashboard tails the file into SQLite for search; the JSONL file stays authoritative. Kept until `devctl history clear` (typed confirm).
- Site logs: `devctl logs SITE --php` (FPM pool slowlog/error), `--web` (Caddy per-site access/error log, `roll_keep_for 168h`), `--db` (container logs), `--vite` (journal of the transient unit, or a log file for terminal runs).

## 12. Install / init process (ADR-0012)

1. `git clone`/copy repo → `./install.sh` (user-level only): symlink `~/.local/bin/devctl`, completion in `~/.local/share/bash-completion/completions/devctl`, desktop launcher (`share/desktop/devctl-dashboard.desktop.in` → `~/.local/share/applications/` and `~/Desktop/`, icon → `~/.local/share/icons/hicolor/scalable/apps/devctl.svg`), no sudo (ADR-0022).
2. `devctl init [--dry-run]`: idempotent, re-runnable; each step = **check → plan (exact commands) → confirm → apply → verify**; already-done steps print ✓ and are skipped:
   1. XDG directories and modes; Btrfs data subvolume + `chattr +C`.
   2. Install privileged helper + polkit policy.
   3. Packages (one confirm, listed): `caddy php-fpm nss-tools uv gh ShellCheck bats …` (Fedora repos). Remi only on separate request.
   4. fnm (user-local) + Node 26.
   5. Static hostname `zaitoune-laptop`.
   6. Docker: disable at boot, `daemon.json` address pools.
   7. Caddy base config (`/etc/caddy/Caddyfile` with the devctl import, admin API on a unix socket). Caddy is not enabled at boot; devctl starts it on demand like Docker (open point 4).
   8. CA trust in system, Brave, Firefox.
   9. Background timer.
   10. Run `doctor` and print the summary.
3. Rebuilding a fresh Fedora machine = steps 1–2 on the new machine (+ restoring data when backups exist).

## 13. Extensibility

- **Project template** = folder in `templates/projects/<id>/` with `template.conf` (name, kind php|static|proxy, runtimes, needs_db, default engine prompt) and optional hooks `create.sh`, `post-clone.sh`, `env.sh`. Discovered automatically; appears in menu, completion and dashboard.
- **DB engine / service** = folder in `templates/engines|services/<id>/` with `engine.conf` + `compose.tmpl`.
- **Adapter** = file implementing a documented function interface; selected by config key (`engine.adapter = docker`, `web.adapter = caddy`, `dns.adapter = hosts`, `tunnel.adapter = cloudflared`).
- **Command** = `lib/cmd/<noun>.sh` with `cmd_<noun>_<verb>` functions + `help_<noun>`; router and completion pick it up.
- **Hook points** (named, no-op until implemented): `pre-destructive`, `post-site-create`, `post-site-delete`, `share.*`, `backup.*`.

## 14. Testing strategy

- `make lint`: shellcheck (severity style) on every `.sh`, `bin/`, `libexec/`.
- `make test`: bats unit tests; external commands (`docker`, `sudo`, `caddy`, `systemctl`, `notify-send`) replaced by PATH stubs that record calls, so tests assert *exact argv* without touching the system. `HOME` is a temp dir.
- `make itest`: opt-in integration tests against real Docker with throwaway names (`devctl-test-*`), never run automatically.
- Dashboard: Python `unittest` (stdlib).

## 15. Open points for approval

These are design choices I've made on your behalf; approving the architecture approves them unless you change them:
1. **Node via fnm** (not in Fedora repos — single binary from GitHub releases into `~/.local/bin`, checksum-verified). Fedora only packages Node 20/22/24; Node 26 LTS isn't there.
2. **Java via Fedora OpenJDK packages side by side**, not SDKMAN (`.sdkmanrc` still read).
3. **PHP**: Fedora's 8.5 now; Remi SCL only when a project needs an older version (asked then).
4. **Caddy on demand** (started by devctl like Docker) vs enabled at boot. Proposed: on demand, consistent with "nothing at boot".
5. **Object storage**: MinIO is archived/discontinued → **RustFS** (Apache-2.0, MinIO-compatible API) proposed; alternatives Garage (AGPL), SeaweedFS (Apache-2.0). Decided finally in module 13 (ADR-0017).
6. **PostgreSQL default major 18** with pgvector (`pgvector/pgvector:pg18`), MySQL 8.4 LTS, MariaDB 11.8 LTS — exact tags verified in module 7.
7. **First clone dependency install** shows the commands (`composer install`, `npm ci`) and asks once, because they run repo-defined scripts.
