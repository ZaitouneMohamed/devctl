# ADR-0003: Caddy as the single front door

- Status: Accepted
- Date: 2026-11-05

## Context
All local domains need HTTP/HTTPS, PHP-FPM, static files, reverse proxy with WebSockets, safe reloads.
## Decision
Fedora's `caddy` package (2.10.2 in F44 updates) as the system service. Main Caddyfile imports `/etc/caddy/devctl/*.caddy`. Site files are rendered as the user and applied by the privileged helper: stage → `caddy validate` → swap → reload → restore last-known-good on failure. Admin API on a unix socket only. Caddy listens on loopback only while sharing is parked. Proposed: not enabled at boot; started on demand.
## Consequences
- Confined as `httpd_t` (to verify on install) → project files need SELinux labels (see ARCHITECTURE §5).
- Web server is behind the `web` adapter so it can be swapped.
