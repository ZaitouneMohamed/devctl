# devctl — Requirements

Status: living document. Last updated 2026-11-05.
Source: the original project brief, the Phase 0 audit and the answers to open items.
Decisions with rationale live in [decisions/](decisions/). This file states *what*, not *why*.

Legend: **MUST** = required for v1 · **SHOULD** = planned · **PARKED** = designed as hook points only, not built.

---

## 1. Purpose

`devctl` is a personal Local DevOps Management System for one Fedora laptop (daily driver, not a server):
one Bash CLI plus a local web dashboard that manage Docker services, websites, databases, local domains,
AI models and cloud tools. Long-lived, modular, secure, maintainable, extensible.

## 2. Target environment (verified 2026-11-05)

| Item | Value |
|---|---|
| OS | Fedora 44 Workstation, kernel 7.2, Bash 5.3.9 |
| Security | SELinux enforcing (stays on), firewalld running |
| Name resolution | systemd-resolved stub, NetworkManager, Avahi active, LLMNR on |
| Hardware | i7-1365U (12 threads), 23 GiB RAM, 8 GB zram, Intel Iris Xe (no GPU) |
| Storage | 512 GB NVMe, Btrfs, `/` and `/home` on the same partition, **no LUKS** |
| Containers | docker-ce 29.9.2 (docker-ce-stable repo), Compose v5.6.1, Podman 5.8.9 |
| Desktop | GNOME, Ptyxis terminal, Brave (primary) + Firefox (RPM), VS Code (RPM) |
| VMware | vmnet1 192.168.227.0/24, vmnet8 192.168.108.0/24 |
| LAN | Wi-Fi 192.168.11.0/24, router/DNS 192.168.11.1 |
| Git host | GitHub via `gh` (not installed yet) |

## 3. Functional requirements

### 3.1 Projects and folders
- MUST: projects root `~/Desktop/projects`, with categories `elden` (work), `personal`, `school`. Category is folder-only; all share the same DB servers and settings.
- MUST: project types to support over time: Laravel + Inertia + React, plain Java, Spring Boot, static HTML/CSS/JS, Python/AI, cloud labs.
- MUST: day-one template **Laravel + Inertia + React only**; adding a template = adding a folder (no code change in core).
- MUST: create a project from a template or by cloning a GitHub repo. The user types the domain name; devctl validates format and uniqueness.
- MUST (template project): ask which DB engine each time; create the database and a least-privilege user; write connection details into `.env`.
- MUST (cloned project): install dependencies once after first clone (asked). Changed 2026-11-06 (ADR-0024): the database is always set up — engine guessed from the project and confirmed, database + least-privilege user created, connection written to `.env` (created from `.env.example` if missing; Spring: `devctl.env`) — and devctl asks how to fill it: run migrations, import a dump file, or leave it empty. Also available later for any site: `devctl site db` / dashboard "Database…".
- MUST (clone with its own docker-compose or Sail): ask once — use devctl shared services, use the repo's compose as-is, or ignore — and remember the answer per project; changeable later. Never edit the repo's files. Warn on ports not bound to 127.0.0.1 or conflicting with the registry.
- MUST: git hooks (post-merge, post-checkout) only send a desktop notification.
- MUST: deleting a project removes only its setup (domain, web-server config, hosts entry, registry entry). Folder and database stay. Confirmation by typing the project name.

### 3.2 Runtimes
- MUST: hybrid model — services in Docker; PHP, Composer, Node, Java, Python on the host, pinned per project via standard files (`.nvmrc`/`.node-version`, `.java-version`/`.sdkmanrc`, `.python-version`, `composer.json` PHP constraint or `.php-version`).
- SHOULD: per-project opt-in to a containerized runtime for old/special versions.
- Defaults (verified): **PHP 8.5** (Fedora 44 ships 8.5.12), **Node 26 LTS**, **Java 25 LTS**, **Python 3.14** (3.15 is newest; 3.14 is also Fedora's system Python). Databases and services at latest stable/LTS, pinnable per project.
- MUST: Laravel served by host PHP-FPM (running as the user) behind the web server; several PHP versions side by side. Adding Remi requires explicit approval.
- MUST: queue workers, scheduler, Reverb are started manually by the user, not managed with the site.
- MUST: CLI-started dev processes (Vite, Java app, …) run in the foreground of the calling terminal; Ctrl+C or closing it stops them.
- MUST: dashboard-started dev processes run as **transient** systemd user units; the dashboard streams their logs and can stop them. Never enabled, never survive logout/reboot.

### 3.3 Web server, domains, HTTPS
- MUST: Caddy is the single front door for all local domains. Docker services publish on 127.0.0.1 only.
- MUST: Caddy proxies WebSockets (Vite HMR), serves static sites, talks to several PHP-FPM sockets, validates config before reload, keeps the last known-good config and rolls back on failure.
- MUST: suffix `.test` (configurable); exactly one name per project, no subdomains.
- MUST: hosts entries live in a marked block in `/etc/hosts`; lines outside the block are never touched; edits go through a minimal validated privileged helper.
- MUST: HTTPS by default via Caddy's local CA, per-project opt-out. Trust in Brave (`~/.pki/nssdb`), Firefox (needs `nss-tools`), system store, Node (`NODE_EXTRA_CA_CERTS`) and Java.
- MUST: Vite HMR works over HTTPS deliberately (no mixed content, no `--host 0.0.0.0`).
- MUST: SELinux stays enforcing; devctl sets correct file contexts per project, including writable `storage/` and `bootstrap/cache/`. Permissive mode is never suggested.
- MUST: static hostname `zaitoune-laptop` (set by `devctl init`, after asking).

### 3.4 Sharing — PARKED
LAN and public sharing are parked until a later discussion (2026-11-05). Only hook points are designed.
Recorded preferences for when it resumes:
- LAN: off by default, per-site command, auto-off after 1 h, `zaitoune-laptop.local:PORT`, one port per site; plain HTTP by default with `--https` opt-in (phone installs the CA once).
- Public: `devctl share SITE --for 1h`, swappable tunnel adapter (Cloudflare quick tunnel first), systemd user unit with hard runtime limit, password by default, APP_DEBUG warning, APP_URL/Vite handling, `share list|stop`.
- Firewall: the default zone `FedoraWorkstation` opens 1025–65535 TCP/UDP inbound; must be resolved before LAN sharing is built.

### 3.5 Databases and services
- MUST engines (each an engine template: image, port, data location, healthcheck, backup method): MySQL, MariaDB (separate engine), PostgreSQL with pgvector, MongoDB, Qdrant, SQLite (file only, no container).
- MUST: Redis is cache-only — no persistence, no backups, no GUI; `devctl db shell` can open `redis-cli`.
- SHOULD services: mail catcher (Mailpit at `mail.test`, never LAN-reachable), Meilisearch, Elasticsearch, S3-compatible object storage (**not MinIO** — see ADR-0017), RabbitMQ, Kafka.
- MUST topology: one shared server per engine + major version; dedicated per-project server on request.
- MUST: least-privilege per-project DB users with generated passwords; root credentials only in devctl's secrets directory, never in a project.
- MUST: servers start on demand with reference counting.
- MUST: each server gets a host port once, recorded in a registry, never changed.
- MUST: DB data outside `~/Desktop`, on Btrfs with copy-on-write disabled before first start.
- MUST: GUI is TablePlus for all databases (replaces DBeaver; DBeaver is not removed without asking). Qdrant uses its own web dashboard on 127.0.0.1. Root DB access is a separate explicit command.
- MUST: `devctl db import` / `devctl db export` through the containers.
- MUST crash recovery: a container is restarted a few times automatically; if it keeps crashing it stays stopped and the user is notified.
- MUST: notify when a newer image exists; never update automatically.
- MUST: Docker does not start at boot; devctl starts it on demand (sudo).
- Legacy: the existing `dev-mysql` / `dev-postgres` containers, their volumes and both compose files in `~/Desktop/projects/databases` are discarded once devctl's DB module works (each removal shown and confirmed).

### 3.6 AI and cloud
- MUST: one shared Ollama server: start, stop, list, pull, remove models; models stored in `~/.local/share/devctl/models`. CPU-only.
- SHOULD: `devctl cloud start|stop` for kind (Kubernetes), Terraform, LocalStack and similar; each tool behind an adapter.

### 3.7 CLI experience
- MUST: command `devctl` with subcommands, flags, colors (auto-off when not a TTY or `NO_COLOR`), help text, config files, consistent errors.
- MUST: interactive menu when run with no arguments — pure Bash, fzf used for pickers only if installed.
- MUST: Bash Tab completion for commands, flags, project names.
- Command set (illustrative): `status` (snapshot) and `status --watch` (live), `site create|list|start|stop|delete`, `domain list`, `db …`, `logs PROJECT [--php|--db|--web|--vite]`, `ai …`, `cloud …`, `doctor`, `init`, `dashboard`.
- MUST: logs kept 7 days.
- MUST: no automatic health checks; health is shown only by `status` and the dashboard.
- MUST: `devctl doctor` reports each problem and offers a fix, asking before each fix. Checks include: certutil present; CA trusted per browser; LLMNR enabled (risk); disk encryption (informational); SELinux state; hostname; Docker not enabled at boot; VMware vs Docker subnet overlap; port 80/443 conflicts; firewall zone open port range (informational while sharing is parked). Avahi is expected, not a finding.
- MUST: nothing starts at login, except the background check timer (ADR-0010). Sleep/wake: do nothing.
- MUST memory guard: before starting a heavy service (Java app, Elasticsearch, Kafka, DB engine, Ollama model), if available RAM < 25 % (~5.7 GB), counting running VMware VMs, warn and ask.
- MUST disk guard: warn at ≤ 20 % free; desktop notifications via `notify-send`.
- MUST privilege: ordinary `sudo` with password; no NOPASSWD rules.

### 3.8 Dashboard
- MUST: started only by `devctl dashboard`; served at `devctl.test`, reachable only from this laptop.
- MUST: a "devctl Dashboard" icon on the desktop (and in the app grid) runs `devctl dashboard`. Desktop icons need a GNOME extension (ADR-0022).
- MUST: Python with Fedora's system Python, SQLite, live updates.
- MUST: every action is executed by calling `devctl`; the CLI is the single source of truth.
- MUST: same confirmations as the CLI (type the project name to delete).
- MUST: admin actions show a graphical polkit password prompt; passwords never pass through the browser.
- MUST: history of actions and alerts from both CLI and dashboard, kept until cleared (so the CLI records every action).

### 3.9 Backups — PARKED
Only hook points (`pre-destructive`, `backup.run`, `backup.verify`). Earlier preferences: local disk only, every 3 days keep 3, backup before destructive operations, encrypted folder for secrets and backups unlocked once per login, restore-verify command.

## 4. Non-functional requirements

### Safety
- No destructive, privileged or system-changing command (sudo, dnf, systemctl enable/disable, /etc edits, firewall, SELinux, hostname, deletions, docker rm/prune) runs without showing the exact command and getting consent.
- Ask before installing packages, adding third-party repos or changing system settings.
- Every dangerous devctl operation supports `--dry-run` and explicit confirmation.
- Secrets are never printed or committed; `.env` files are 0600 and git-ignored.

### Engineering
- Bash for orchestration; other languages only where Bash is a poor fit (dashboard = Python).
- `set -Eeuo pipefail` where appropriate, quoting, input validation, small functions in modular files, traps/cleanup, meaningful exit codes, no `eval`, no command strings built for execution.
- Modular, DRY, separation of concerns, idempotent, consistent error handling, central logging, config-driven.
- shellcheck clean; tests with bats.
- Every container-engine call goes through one wrapper. Every DNS, web server, DB engine, tunnel and runtime manager sits behind an adapter or template.

### Process
- Phase 2 builds one module at a time: purpose, requirements, interface, implementation, Bash concepts, tests, edge cases, command docs → approval → commit.
- Repository: `~/Desktop/projects/personal/devctl`, local git only for now (no GitHub).
