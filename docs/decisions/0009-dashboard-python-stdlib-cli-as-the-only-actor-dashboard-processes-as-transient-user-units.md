# ADR-0009: Dashboard: Python stdlib, CLI as the only actor; dashboard processes as transient user units

- Status: Accepted
- Date: 2026-11-05

## Context
Dashboard needs live view and actions without becoming a second source of truth. Dev processes from the CLI run in a foreground terminal.
## Decision
Python (Fedora system Python, stdlib only: http.server, sqlite3, subprocess), SSE for live updates, every action executes `devctl … --json`. Processes started from the dashboard run via `systemd-run --user --collect` as transient units; logs streamed from the journal; Stop stops the unit. CLI-started processes stay in the foreground.
## Implementation notes (2026-11-05, module 18a)
- Built before the CLI modules it displays, at the user's request; pages are added per module.
- The dashboard server itself runs as a transient user unit (`devctl-dashboard.service`).
- Until Caddy exists it is served on `http://127.0.0.1:7780` with one-time login codes, Host check and CSRF tokens; it moves to `https://devctl.test` with modules 3, 8 and 9.

## Consequences
- No pip dependencies; one behavior source.
- Two run modes for dev processes; `status` shows both.
