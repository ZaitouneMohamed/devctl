# ADR-0023: Caddy confined by SELinux (httpd_t), user caddy, read-only ACLs per project

- Status: Accepted (2026-11-05) — refines ADR-0003
- Date: 2026-11-05

## Context
Verified on Fedora 44: `/usr/bin/caddy` is labelled `bin_t`, so caddy.service runs
**unconfined**; it runs as user `caddy`; the home folder is 0700, so Caddy cannot read
projects. ADR-0003 assumed Caddy would be confined like Apache.

## Decision
- Label Caddy like Apache so SELinux confines it as `httpd_t` (semanage fcontext):
  `/usr/bin/caddy` → `httpd_exec_t`, `/etc/caddy(/.*)?` → `httpd_config_t`,
  `/var/lib/caddy(/.*)?` → `httpd_var_lib_t`, `/run/caddy(/.*)?` → `httpd_var_run_t`.
- Booleans: `httpd_can_network_connect` (proxy to local apps: dashboard, Vite, Java) and
  `httpd_enable_homedirs` (traverse home folders to reach labelled projects).
- Port range 44300–44399 labelled `http_port_t` for per-site Vite HTTPS listeners.
- Caddy keeps running as `caddy`; each project gets read-only ACLs (home and parents:
  traverse only; project: read, inherited by new files) and SELinux labels
  `httpd_sys_content_t` (writable folders `httpd_sys_rw_content_t` for PHP-FPM, which Fedora
  already confines as `httpd_t`).
- Admin API on a unix socket in `/run/caddy` (no TCP admin port).

## Consequences
- Least privilege for the front door; SELinux denials possible while tuning
  (`journalctl -t setroubleshoot`, `ausearch -m avc` as root).
- Every system change goes through the helper (verbs `web-selinux-setup`, `caddy-setup`,
  `caddy-apply`, …) and is shown and confirmed first.
