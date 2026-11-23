# Module 14 — Background checks

Status: built and tested · 2026-11-11 · implements [ADR-0010](../decisions/0010-background-checks-via-an-always-on-systemd-user-timer.md)

`devctl watch enable` installs a systemd **user** timer (`~/.config/systemd/user/devctl-watch.{service,timer}`):
first run 5 min after login, then every 30 min, low priority, `DEVCTL_SOURCE=timer`. It runs
`devctl --quiet watch tick`:

| Check | When | Alert |
|---|---|---|
| disk | every tick | free ≤ `guard.disk_min_free_percent` → critical notification + `disk-low` alert; repeated at most every 6 h; reset when space is back |
| crashes | only if Docker is already active | devctl containers exited non-zero after their restarts (`on-failure:3`) → once per crash |
| images | once a day, only if Docker is active | a downloaded server image whose tag now points to a newer digest (`docker buildx imagetools`) → once per new digest; **never pulls or updates** |
| logs | every tick | devctl logs older than `log.retention_days` removed |

Alerts: desktop notification (`notify-send`, new `lib/core/notify.sh`), `devctl history --alerts`,
and live toasts in the dashboard. Each check is isolated: a failing one is reported as skipped.
Commands: `devctl watch [status|enable|disable|tick [--force]]`. Doctor check `watch` (fix:
enable) and an init step. Tests: `tests/unit/watch.bats` (7). Bug caught by lint: a variable
named `local`.
