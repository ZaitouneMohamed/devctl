# ADR-0005: HTTPS by default with Caddy local CA; Vite HMR via per-site TLS port

- Status: Accepted
- Date: 2026-11-05

## Context
HTTPS everywhere locally, per-project opt-out; Vite HMR must work over HTTPS without subdomains.
## Decision
Caddy `local_certs`. Trust installed (with consent) into the system store, Brave NSS db, Firefox profiles, Node (`NODE_EXTRA_CA_CERTS`), Java (via Fedora system store; verify). Each site gets a registered Vite port V: Caddy serves `https://<name>.test:V` → `127.0.0.1:V+10000` where Vite listens.
## Consequences
- Same certificate and host as the app → no mixed content, no CORS surprises.
- Root CA key is unencrypted on disk (no LUKS) → never installed on other devices by default.
