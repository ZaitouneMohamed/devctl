# Module 8 — Web server (Caddy) and HTTPS

Status: built and unit-tested · real run pending your `devctl web setup` · 2026-11-05
Implements ADR-0003, ADR-0005, ADR-0023 (new: Caddy confined by SELinux, user caddy, ACLs).

## Verified facts that shaped it
- Fedora 44 `caddy` 2.10.2: binary labelled `bin_t` → runs **unconfined** unless relabelled;
  runs as user `caddy`; home folder is 0700 → no access to projects without grants.
- PHP-FPM from Fedora is already confined (`httpd_t`) → project labels matter for PHP.

## Setup (`devctl web setup`, helper verbs, each shown and confirmed)
1. `pkg-install caddy` (Fedora repos only).
2. `web-selinux-setup`: `/usr/bin/caddy` → `httpd_exec_t`, `/etc/caddy` → `httpd_config_t`,
   `/var/lib/caddy` → `httpd_var_lib_t`, `/run/caddy` → `httpd_var_run_t`; booleans
   `httpd_can_network_connect`, `httpd_enable_homedirs`; ports 44300–44399 → `http_port_t` (Vite).
3. `caddy-setup`: devctl's `/etc/caddy/Caddyfile` (original kept as `Caddyfile.devctl-orig`):
   admin API on `unix//run/caddy/admin.sock`, `local_certs`, `skip_install_trust`,
   `default_bind 127.0.0.1 [::1]`, `import /etc/caddy/devctl/*.caddy`; systemd drop-in
   `RuntimeDirectory=caddy`. Caddy is not enabled at boot.

## Sites
- Templates `templates/caddy/{php,static,proxy}.caddy.tmpl`; HTTPS by default, `http://` when
  a site turns TLS off. Rendered as you into `~/.local/share/devctl/caddy/sites/` (desired state).
- `caddy-apply` (root): mirrors staging → `/etc/caddy/devctl` (names, owner, size, type checked),
  `caddy validate` with throwaway storage, reload if running; **any failure restores the previous
  files**; keeps the last good set → `devctl web rollback`.
- Applied only when staging differs from what Caddy serves (no needless password prompts).

## HTTPS trust (`devctl web trust`)
Starts Caddy once (it creates its CA), exports the public CA certificate to
`~/.local/share/devctl/ca/root.crt`, then: system store (`ca-trust-system` → curl, PHP, Python,
Java, Firefox via p11-kit), Brave (`~/.pki/nssdb`, created if missing), every Firefox profile
(`~/.mozilla/firefox/*`, `~/.config/mozilla/firefox/*`) with `certutil -A -t C,,`.
Node: `NODE_EXTRA_CA_CERTS` from that file (set by the runtimes module).
The CA private key stays in `/var/lib/caddy` (root/caddy only).

## Dashboard at https://devctl.test
`devctl dashboard` adds the `devctl` proxy site and the `devctl.test` name, applies them when
needed, starts Caddy and opens `https://devctl.test/login?code=…`. The dashboard server accepts
`devctl.test` as Host. Before Caddy is set up it stays on `http://127.0.0.1:7780`.
Without a terminal (desktop icon), admin prompts use pkexec (desktop password dialog).

## Doctor / init
New checks `web` and `https-trust` (with fixes `devctl web setup` / `devctl web trust`); init's
system step includes both.

## Tests
`tests/unit/web.bats` (12): rendering (HTTPS/HTTP, proxy, refusal of unsafe paths/names/sockets,
dry-run, remove, staging location), trust detection and import plan (stubbed certutil), DNS list
and apply-only-when-different, hosts-block filtering, helper verb argument checks, CLI paths.
`make check`: lint + 163 bats + 23 Python — pass. Not yet run for real (needs your password).

## Fix after the first real site (2026-11-05)
Fedora's caddy.service has `ProtectHome=true`: all of /home is invisible to Caddy, so every
file returned 403 (no SELinux denial). devctl's drop-in now sets `ProtectHome=tmpfs` +
`BindReadOnlyPaths=~/Desktop/projects`: Caddy sees only the projects folder, read-only;
ACLs and SELinux labels still apply inside it. `web_configured` checks for this drop-in.
The polkit action uses `auth_admin_keep` (password remembered a few minutes, like sudo), so
one action with several admin steps asks once instead of once per step.
