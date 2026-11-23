# Module 11 — Sites (+ dashboard Sites page)

Status: done — first site (shop, MySQL) created and verified on this laptop · 2026-11-05

## Commands — [docs](../commands/site.md)
`site [list]`, `create NAME [--category] [--db] [--template]`, `clone URL [--name] [--category]`,
`start|stop NAME`, `dev NAME` (Vite, foreground), `open`, `info`, `delete NAME` (type the name).
Missing category/engine are asked in a terminal (engine every time, per requirements).

## Create (template `laravel-inertia-react`)
1. `composer create-project laravel/react-starter-kit <dir> dev-main` (Laravel 13.17+; the kit's
   tagged v1.0.1 is from Feb 2025 and targets Laravel 12, so devctl follows the official installer).
2. Database: shared server for the engine (started), database + user `<name>` with a new
   password (MySQL, MariaDB, PostgreSQL+pgvector) or SQLite file; `.env` gets `APP_URL`,
   `DB_*`; `.env` is 0600 (Laravel's `.gitignore` already excludes it).
3. `php artisan migrate`, `npm install`, `npm run build` (project's Node version via fnm).
4. Vite port from 44300–44399 (recorded forever); `devctl.vite.config.ts` added and git-excluded.
5. Serve: Caddy site (PHP-FPM socket + Vite HTTPS listener), read-only ACLs for `caddy`
   (parents traverse-only; only `public/` readable — never `.env` or sources), SELinux labels
   (helper `project-label`: project `httpd_sys_content_t`, `storage/` and `bootstrap/cache/`
   `httpd_sys_rw_content_t`), `NAME.test` in /etc/hosts, apply (validated), PHP-FPM + Caddy started.
6. Git hooks (if `.git`): post-merge / post-checkout → desktop notification only.

## Clone
`git clone`; detects Laravel or static; repo's own compose/Sail → asks once, remembered as
`compose_policy`; dependency install (runs repo scripts) asked once; then the same serve step.
`.env`, database and migrations are yours.

## Start / stop / dev / delete
- start: acquire the site's database server (refcount) + serve; stop: release (server stops at 0).
- dev: `vite --config devctl.vite.config.ts` in the foreground (Ctrl+C stops), live reload at
  `https://NAME.test:<vite port>` → page and assets share one trusted origin, no mixed content.
- delete: web config, name, SELinux rules, Caddy ACLs, registry entry removed; folder and database kept.

## Dashboard
New **Sites** page: list with Open / Start / Stop / Delete (typed name, checked again by devctl),
**New site** form (name, category, database). Long actions run as background jobs; the page
streams their output (`/api/jobs/<id>`). Admin steps show the desktop password dialog (pkexec).
Inputs are shape-checked before devctl runs; argv is fixed in the server.

## Tests
`tests/unit/site.bats` (12): naming rules, paths, `.env` editing, Vite ports, Caddy Vite block,
registry, ACL plan (only `public/` readable), git hooks, start/stop refcount + delete keeps data,
CLI create (no terminal → asks for options; dry-run exact composer command), wrapper config.
Dashboard: 5 new Python tests (list, create job with fixed argv + output streaming, bad input
never reaches devctl, delete passes the typed name, unknown job).
`make check`: lint + 184 bats + 36 Python — pass.

## Open points
- First real run may hit SELinux denials (e.g. Caddy traversing `~/Desktop`); fix after your run.
- Dashboard-started Vite (transient unit) comes with module 12/18; for now `devctl site dev`.

## Fixes after the first real run (2026-11-05)
- pkexec does not accept `--` before the program ("Cannot run program --") → no `--` for pkexec.
- Fedora's caddy.service hides /home (`ProtectHome=true`) → every file 403 → Caddy now sees only
  `~/Desktop/projects`, read-only (ProtectHome=tmpfs + BindReadOnlyPaths).
- Five password dialogs for one start → polkit `auth_admin_keep` (remembered a few minutes).
- `site stop` kept serving the site → it now answers "NAME is stopped" (503) until started.
- A failed start leaked a database-server user count → server users are now one marker per site
  (`run/refcount/<server>/<site>`): repeating start/stop or a failed start cannot drift.
