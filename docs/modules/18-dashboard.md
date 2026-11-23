# Module 18 — Dashboard pages

Status: built and tested · 2026-11-11 (AI and cloud pages come with modules 16 and 17)

| Page | Shows | Actions (each a fixed `devctl` command) |
|---|---|---|
| Overview | version, history counts, live status cards, recent activity | — |
| Sites | sites, state, database | New site (templates), Clone from GitHub (+ database), Start/Stop, Database…, Delete (typed name) |
| **Databases** | server cards (engine, fixed port, state, sites using it), databases | New database, Start/Stop server, **Connect…** (host/port/user; password hidden until "Show", Copy buttons), **Export** (downloads the .gz), **Import…** (upload with progress, typed name) |
| **Services** | Mailpit, Meilisearch, Elasticsearch, RustFS, RabbitMQ, Kafka: state, connection hint | Start/Stop, **Open** (Mailpit https://mail.test, RabbitMQ/RustFS consoles, Meilisearch) |
| **Logs** | per site: web requests, Laravel log, PHP errors, database server | lines 100–1000; **Follow** refreshes every 2.5 s, new lines flash |
| Setup | GitHub CLI, sign-in (device code / token), git identity | install, sign in/out, save identity |
| History / Settings | as before | clear history (typed) |

Security of the new endpoints: names checked against strict patterns before devctl runs;
log parts from a fixed list; exports run in `run/exports/` and only files matching
`NAME-ENGINE-YYYYmmdd-HHMMSS.EXT.gz` there can be downloaded (traversal attempts → 404); exports
and uploads are removed after a day. New CLI JSON: `db list --databases`, `svc info`.
Tests: 6 Python (pages) + 2 bats (JSON).
