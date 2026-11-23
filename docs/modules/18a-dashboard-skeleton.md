# Module 18a — Dashboard skeleton

Status: built, awaiting approval · 2026-11-05. Moved ahead of the roadmap at your request;
each later CLI module adds its own dashboard page (module 18 completes it).

## Purpose
A local web dashboard you can open from the desktop icon today, with the security model,
live updates and the "every action goes through the CLI" pipeline in place, so later
modules only add pages.

## What it does now
| Page | Content | Source |
|---|---|---|
| Overview | devctl version, number of recorded actions/alerts, recent activity (live), cards for upcoming modules | `devctl --json version`, history index |
| History | all actions and alerts, filter by type/source/text, live; **Clear history…** with typed confirmation | history index; clear = `devctl history clear` |
| Settings | every setting, value, where it comes from | `devctl --json config show` |

New CLI commands: [`devctl dashboard [open|start|stop|status|url]`](../commands/dashboard.md),
[`devctl history [list|clear]`](../commands/history.md).

## How it works
```
desktop icon / terminal ──► devctl dashboard
                              ├─ systemd-run --user --unit=devctl-dashboard (transient, not at login)
                              │     └─ /usr/bin/python3 -I dashboard/main.py  → 127.0.0.1:7780
                              └─ writes one-time login code (0600 file) → xdg-open http://127.0.0.1:7780/login?code=…
browser ──► /login?code  → code file deleted, HttpOnly SameSite=Strict session cookie
        ──► /api/*       → reads history index (SQLite) or runs `devctl --json …` (DEVCTL_SOURCE=dashboard)
        ◄── /api/events  → Server-Sent Events: new history rows, "reset" after a clear
```

## Security
- Listens on `127.0.0.1` only; `Host` must be `127.0.0.1:<port>` (blocks DNS rebinding) → else 421.
- Login: one-time codes, valid 2 minutes, must be owned by you with mode 0600; reused codes → 401.
- Session cookie `HttpOnly; SameSite=Strict`; sessions live in memory (restart = log in again via the icon).
- Every POST needs `X-Devctl-CSRF` (per-session token) and `Content-Type: application/json`, body ≤ 16 KiB.
- Strict CSP (`default-src 'none'`, scripts/styles only from the server), `nosniff`, `no-referrer`, `no-store`.
- Frontend inserts all data with `textContent`; no `innerHTML`.
- Actions are fixed argv lists in server code; browser input is only ever a single argument
  value (the typed confirmation), which the CLI checks again. No shell anywhere.
- Python runs with `-I` (ignores PYTHON* env vars, user site-packages, current dir); standard library only.
- Plain HTTP for now: traffic never leaves the loopback interface. Moves to `https://devctl.test`
  behind Caddy with modules 3, 8 and 9.

## Files
```
dashboard/main.py                 entry point (adds its own dir to sys.path; -I mode)
dashboard/devctl_dash/server.py   HTTP server, routes, SSE, startup/shutdown, state file
dashboard/devctl_dash/auth.py     login codes, sessions, Host and CSRF checks
dashboard/devctl_dash/history.py  SQLite index of history.jsonl (incremental, detects clear/replace)
dashboard/devctl_dash/cli.py      runs devctl --json …
dashboard/static/                 index.html, app.css, app.js, devctl.svg
dashboard/tests/                  23 unittest tests (auth, history index, real HTTP server with fake CLI)
lib/cmd/dashboard.sh, lib/cmd/history.sh
```
Runtime files: `~/.local/state/devctl/run/dashboard.json` (port/pid while running),
`~/.local/state/devctl/run/dashboard-login/` (one-time codes), `~/.local/state/devctl/dashboard/history.sqlite`.

## Edge cases
| Case | Behavior |
|---|---|
| Icon clicked while already running | no second server; just a new login link |
| Port 7780 taken | `devctl dashboard` exits 5 and names the setting to change |
| Server fails to start | exit 9 with the `journalctl --user -u devctl-dashboard` command |
| Old failed unit blocks the name | `reset-failed` before starting |
| Browser can't be opened | link printed (valid 2 min); `devctl dashboard url` makes a new one |
| History cleared/replaced while the page is open | index rebuilt, page refreshes via `reset` event |
| Half-written last line in history | imported on the next sync |
| Dashboard restarted | old cookie invalid → page shows "open with the icon" |
| Wrong typed confirmation | CLI refuses (exit 6 → HTTP 409), recorded as `aborted` from `dashboard` |

## Verified
- `python3 -I -m unittest` — 23 tests pass.
- Real run: start (and `--dry-run`), status, one-time login (reuse → 401), overview, settings,
  forged Host → 421, wrong confirmation → refused and recorded, correct clear → live `reset` + new
  row pushed over SSE, stop removes the state file, port bound to 127.0.0.1 only.
- Not yet: clicking through the pages in Brave yourself (please do), bats tests for the two new CLI commands.
