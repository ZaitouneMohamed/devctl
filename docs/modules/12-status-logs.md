# Module 12 — Status and logs

Status: built and tested · 2026-11-05

## devctl status [--watch]
Services (Docker, Caddy, PHP-FPM), memory, disk; each site's health (HTTPS request to
`https://NAME.test/`, 3 s timeout; running sites only); each database server's health (its
container healthcheck) and which sites use it. `--watch` refreshes every 3 s; `--json` for the
dashboard, whose Overview now shows these as cards. Health is only checked on request
(requirements: no background health checks).

## devctl logs SITE [--app] [--php] [--web] [--db] [-f] [-n N]
| Part | Source |
|---|---|
| app | `storage/logs/laravel.log` |
| php | journal tag `devctl-php`, lines mentioning the site's folder |
| web | Caddy's JSON journal, requests whose host is the site (incl. its Vite port) |
| db | the site's (shared) database server container |
Default: app + web, 50 lines each; `-f` follows one part.

## Bug found and fixed (module 10)
`/var/log/php-fpm` is owned by apache (0770): PHP running as you could not write its error
log, so PHP errors were lost. The devctl pool now logs to the journal
(`error_log = syslog`, ident `devctl-php`); `devctl runtime` reports an older pool as
"pool outdated" and `devctl runtime setup php` rewrites it (helper version 9).

## Tests
`tests/unit/status.bats` (6): status JSON shape, `--watch` needs a terminal, logs option
errors, app log tail, web log filtering (other sites and non-JSON lines skipped), pool check.
