# Module 13 — Extra services

Status: built and tested (unit + all six on real Docker) · 2026-11-06

| Service | Image (verified on Docker Hub) | Ports (127.0.0.1, fixed forever) | Data | Notes |
|---|---|---|---|---|
| mailpit | `axllent/mailpit:v1.33` | SMTP 1025, UI 8025 → **https://mail.test** | in memory | catches every email your apps send |
| meilisearch | `getmeili/meilisearch:v1.56` | 7700 | yes | generated master key |
| elasticsearch | `elasticsearch:9.5.5` | 9200 | yes | single node, security off (loopback only), 1 GiB heap, heavy → memory warning |
| rustfs | `rustfs/rustfs:1.0.4` | S3 9000, console 9001 | yes | S3-compatible (ADR-0017), generated access/secret keys |
| rabbitmq | `rabbitmq:4.4-management-alpine` | 5672, UI 15672 | yes | user `devctl`, generated password |
| kafka | `apache/kafka:4.4.0` | 9092 | yes | single KRaft node (no ZooKeeper), heavy → memory warning |

`devctl svc [list] | start | stop | info [--show-secrets] | logs [-f]` — [docs](../commands/svc.md).
`svc info` prints the lines to put in a project's `.env` (secrets only with `--show-secrets`).

## How
Services are engine templates with `category = service` (same folder as the databases), so they
reuse the server machinery: registry, fixed ports, secrets (0600), No-CoW data folders, start on
demand, memory guard, health. New in the engine format: `extra_ports = name:default` (each
recorded forever, placeholder `{{PORT_NAME}}`), several generated secrets
(`root_secret = KEY KEY`), fixed settings (`static_env`), `web_name` (a Caddy site, e.g. `mail`),
`{{UID}}/{{GID}}` placeholders, `hint`.

## Decisions found by testing on real Docker
- RustFS runs as UID 10001 and Kafka/Elasticsearch as fixed users → devctl runs them as **your
  UID** (Elasticsearch: your UID with group 0, which the image supports), so they own their data
  folder without root chown. Verified: files written as you.
- Kafka's image declares two extra volume paths → mounted as `tmpfs` (no stray Docker volumes).
- Fresh install (no registry yet) crashed `devctl svc` → registry reads are guarded (regression test).

## Tests
Unit `tests/unit/svc.bats` (8). Integration `tests/integration/svc.bats` (6, real Docker, isolated):
Mailpit receives an SMTP email; Meilisearch rejects requests without the key; RustFS creates a
bucket with SigV4-signed requests and rejects wrong keys; RabbitMQ API with the generated
password; Elasticsearch cluster healthy; Kafka topic created. All pass; nothing left behind.
