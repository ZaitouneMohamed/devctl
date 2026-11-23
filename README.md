<div align="center">

<img src="dashboard/static/devctl.svg" width="96" alt="devctl logo">

# devctl

**A local DevOps control center for Fedora: one CLI and a web dashboard for your sites, databases, services and local HTTPS domains.**

`devctl site clone owner/repo` → **https://repo.test** with its own database, trusted HTTPS, and SELinux still enforcing.

![Bash](https://img.shields.io/badge/Bash-5.2%2B-4EAA25?logo=gnubash&logoColor=white)
![Python](https://img.shields.io/badge/Python-stdlib%20only-3776AB?logo=python&logoColor=white)
![Fedora](https://img.shields.io/badge/Fedora-44-51A2DA?logo=fedora&logoColor=white)
![SELinux](https://img.shields.io/badge/SELinux-enforcing-c00)
![Tests](https://img.shields.io/badge/tests-261%20bats%20%2B%20136%20python-brightgreen)
![ShellCheck](https://img.shields.io/badge/ShellCheck-clean-brightgreen)

</div>

---

## Why

Setting up a laptop for web development usually means a pile of half-remembered commands: a database container here,
an `/etc/hosts` line there, a self-signed certificate the browser complains about, SELinux "temporarily" set to permissive…

**devctl** replaces all of that with one tool that knows how your machine is set up. Every change it makes is shown first,
can be dry-run, is recorded in a history, and keeps the system's security features turned **on**.

## Features

| | |
|---|---|
| 🌐 **Sites** | Create Laravel (Inertia + React, Blade, API), Spring Boot, plain Java or static projects, or clone any GitHub repo. Each gets `https://NAME.test`. |
| 🔒 **Real local HTTPS** | Caddy with its own local CA, trusted by the system, Firefox, Chromium/Brave and Node. Vite hot reload over HTTPS too. |
| 🗄️ **Databases** | MySQL 8.4, MariaDB 11.8, PostgreSQL 18 + pgvector, MongoDB, Qdrant, Redis, SQLite. One shared server per engine version, fixed ports, a least-privilege user per database. Import, export, share a database between sites. |
| 🧰 **Services** | Mailpit (`https://mail.test`), Meilisearch, Elasticsearch, RustFS (S3), RabbitMQ, Kafka. One command each, started only when needed. |
| 🐙 **GitHub** | Sign in with `gh`, browse your repositories (cached), clone private repos. devctl detects the stack and sets up the database (migrate, import a dump, or reuse an existing one). |
| 🐘 **Runtimes** | PHP-FPM per version (8.5 from Fedora, 8.4 side by side from Remi when a project needs it), Node via fnm, OpenJDK 25, Python via uv. |
| 🖥️ **Dashboard** | A local web UI at `https://devctl.test` with Overview, Sites, Databases, Services, Logs, Setup and History. Live updates, one-time login codes, CSRF protection, strict CSP. |
| 🩺 **Doctor** | 20+ checks of the machine with fixes offered one by one. Background alerts for low disk space, crashed containers and image updates. |

## Principles

- **Nothing changes behind your back.** Every privileged step shows the exact command and asks first. `--dry-run` works everywhere.
- **SELinux stays enforcing.** Caddy runs confined as `httpd_t` and only gets read-only ACLs on the project folders it serves. There are no `chmod 777` shortcuts.
- **One audited door to root.** Everything that needs root goes through `devctl-root`, a small helper with a fixed list of verbs that validates every argument. It runs via `sudo` in the terminal or a polkit password dialog in the dashboard. No passwordless sudo.
- **Nothing runs at boot.** Docker, Caddy and database servers start on demand and stop when no site needs them.
- **Secrets stay secret.** Credentials are stored with mode `0600` and never printed unless asked. `.env` files are never committed.
- **Destructive means typed.** Deleting a site, a database or the history requires typing its name.

## Quick start

```bash
git clone https://github.com/ZaitouneMohamed/devctl.git ~/devctl
cd ~/devctl
./install.sh          # user-level install, no sudo: ~/.local/bin/devctl, Tab completion, desktop icon
devctl init --dry-run # see every step and every command, change nothing
devctl init           # set up the machine (asks before each privileged step, safe to re-run)
devctl doctor         # verify
```

Then:

```bash
devctl site create shop --template laravel-inertia-react --db mysql
# → https://shop.test, database "shop", user "shop", migrations done

devctl github setup                     # sign in once
devctl site clone owner/repo            # clone + detect + database + https://repo.test
devctl dashboard                        # open https://devctl.test
```

### Requirements

| | |
|---|---|
| OS | Fedora Workstation 44 (other recent Fedora releases likely work; not tested elsewhere) |
| Shell | Bash 5.2+, `jq`, `curl`, `git`, `acl` |
| Containers | Docker CE with Compose v2 (devctl turns off its start at boot and starts it on demand) |
| Installed by `devctl init` (after asking) | `caddy`, `php-fpm`, `nss-tools`, `uv`, `gh`, `java-25-openjdk-devel`, fnm + Node |

## Usage

Global flags: `--dry-run` · `--yes` · `--json` · `--quiet` · `--verbose` · `--no-color` · `-h`.
Tab completion covers commands, flags, site names, databases and servers. `devctl help COMMAND` shows details.

<details open>
<summary><b>Sites</b></summary>

| Command | What it does |
|---|---|
| `devctl site create NAME [--template T] [--db ENGINE \| --use-db DB]` | New project from a template |
| `devctl site clone OWNER/REPO [--name N] [--db E \| --use-db DB] [--fill migrate\|import\|none]` | Clone, detect, install dependencies, set up the database |
| `devctl site list` / `info NAME` / `open NAME` | Show your sites |
| `devctl site start\|stop NAME` | Start or stop serving a site and its database server |
| `devctl site dev NAME` | Vite (HTTPS + hot reload) or the Spring/Java app, in the foreground |
| `devctl site db NAME [--engine E \| --use DB] [--fill …]` | Attach or replace a site's database |
| `devctl site php NAME [VERSION]` | Show or switch a site's PHP version |
| `devctl site delete NAME [--with-db \| --keep-db]` | Remove the setup. The folder stays; the database is deleted only if you choose to |
| `devctl site templates` | Available templates |

</details>

<details>
<summary><b>Databases</b></summary>

| Command | What it does |
|---|---|
| `devctl db list [--databases]` | Servers (engine, port, state, users) or databases (and which sites use them) |
| `devctl db create NAME --engine E` | Database + its own user with a generated password |
| `devctl db creds NAME` | Connection details for TablePlus, DBeaver and similar tools |
| `devctl db shell NAME` / `db root SERVER` | Client shell as the project user / as superuser |
| `devctl db import NAME FILE` / `db export NAME [FILE]` | Restore or dump through the container (`.sql`, `.gz`, `.dump`) |
| `devctl db drop NAME` | Delete a database no site uses |
| `devctl db start\|stop SERVER` | Manual control (stop refuses while sites use the server) |

</details>

<details>
<summary><b>Services, web, runtimes</b></summary>

| Command | What it does |
|---|---|
| `devctl svc [list\|start\|stop\|info\|logs] NAME` | Mailpit, Meilisearch, Elasticsearch, RustFS, RabbitMQ, Kafka |
| `devctl web [status\|setup\|trust\|start\|stop\|apply\|rollback]` | Caddy and local HTTPS |
| `devctl domain [list\|apply]` | The managed `/etc/hosts` block |
| `devctl runtime [status\|setup]` / `runtime php [list\|add V]` | PHP-FPM, Node, Java, Python |
| `devctl engine [status\|start\|stop]` | Docker on demand |

</details>

<details>
<summary><b>Machine and tooling</b></summary>

| Command | What it does |
|---|---|
| `devctl init [--dry-run]` | Set up or rebuild the machine baseline (idempotent) |
| `devctl doctor` | Diagnose and offer fixes |
| `devctl status` | Services, sites (with an HTTPS check), databases, memory, disk |
| `devctl logs [SITE] [--web\|--php\|--db] [-f]` | Logs per part |
| `devctl watch [enable\|disable\|status]` | Background alerts (systemd user timer) |
| `devctl github [status\|setup\|login\|repos\|identity]` | GitHub sign-in, your repositories, git identity |
| `devctl history [clear]` | Everything devctl did, with alerts |
| `devctl dashboard [open\|start\|stop\|url]` | The web dashboard |
| `devctl self [install\|uninstall\|status]` / `root [install\|status]` | devctl itself and its privileged helper |

</details>

Exit codes: `0` ok · `1` failure · `2` usage · `3` validation · `4` not found · `5` conflict · `6` aborted · `7` precondition · `8` privilege · `9` external tool.

## How it works

```
 terminal: devctl …                 browser: https://devctl.test
        │                                     │
        ▼                                     ▼
  devctl (Bash)  ◄────────── calls ──── dashboard (Python stdlib)
  core · adapters · services · commands
        │                    │                         │
   sudo / pkexec        Docker (adapter)          host runtimes
        ▼                    ▼                         ▼
  devctl-root          DB servers & services     PHP-FPM, Node (fnm),
  hosts · caddy ·      on 127.0.0.1 only         Java, Python (uv)
  selinux · php-fpm
        ▼
  Caddy :443 ──► NAME.test ──► PHP-FPM │ static files │ reverse proxy (Spring, Vite)
```

- **The CLI is the only thing that changes state.** The dashboard, git hooks and the background timer all call it.
- **Every external system sits behind an adapter**: Docker, Caddy, `/etc/hosts`. Each one could be swapped out, for example for Podman.
- **Data follows XDG:** settings in `~/.config/devctl`, registry, secrets and database data in `~/.local/share/devctl` (a No-CoW Btrfs subvolume for databases), logs and history in `~/.local/state/devctl`.

Read more: [Architecture](docs/ARCHITECTURE.md) · [Requirements](docs/REQUIREMENTS.md) · [24 decision records](docs/decisions/README.md) · [Module docs](docs/modules/) · [Command docs](docs/commands/)

## Configuration

Defaults live in [`share/defaults.conf`](share/defaults.conf). Override them in `~/.config/devctl/devctl.conf`:

```ini
projects.root = ~/Desktop/projects
projects.categories = work personal school
system.hostname = my-laptop
domain.suffix = test
dashboard.port = 7780
```

Precedence: defaults < `devctl.conf` < `DEVCTL_*` environment variables < command flags. `devctl config show` shows where each value comes from.

## Development

```bash
make lint            # ShellCheck on every Bash file
make test            # bats unit tests: external commands stubbed, safe to run anytime
make test-dashboard  # Python unittest for the dashboard (no extra packages)
make itest           # real Docker, isolated (temporary HOME, devctl-itest-* containers)
```

```
bin/devctl            entry point
lib/core/             logging, config, validation, UI, locks, history, privilege
lib/adapters/         docker · caddy · hosts
lib/services/         sites, database servers, PHP
lib/cmd/              one file per command (cmd_<noun>_<verb>)
libexec/devctl-root   privileged helper (fixed verbs, validated arguments)
templates/            project templates, database engines and services, Caddy configs
dashboard/            Python standard-library web dashboard
share/                defaults, completion, polkit policy, systemd units, desktop launcher
tests/                bats unit and integration tests
docs/                 requirements, architecture, ADRs, module and command docs
```

**Extending:**
- **Project template:** add `templates/projects/<id>/`.
- **Database engine or service:** add `templates/engines/<id>/` with `engine.conf`, a compose template and a driver.
- **Command:** add `lib/cmd/<noun>.sh`.

Every change is expected to pass `make lint test test-dashboard`.

## Roadmap

- [x] Core, install, privileged helper, doctor, init
- [x] Docker adapter, database servers, services
- [x] Caddy + local HTTPS, local domains, runtimes
- [x] Sites, templates, GitHub clone, shared databases
- [x] Status, logs, background checks, dashboard
- [ ] Interactive terminal menu
- [ ] Local AI models (Ollama)
- [ ] Cloud tooling (kind, Terraform, LocalStack)
- [ ] Sharing a site on the LAN or the internet (designed, parked)
- [ ] Backups (designed, parked)

## License

MIT. See [LICENSE](LICENSE).
