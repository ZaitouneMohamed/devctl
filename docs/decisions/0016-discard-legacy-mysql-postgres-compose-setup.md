# ADR-0016: Discard legacy MySQL/Postgres compose setup

- Status: Accepted
- Date: 2026-11-05

## Context
`~/Desktop/projects/databases` runs `dev-mysql` (mysql:8.4) and `dev-postgres` (postgres:17), restart unless-stopped, named volumes, 3 plaintext passwords in identical `compose.yam`/`compose.yaml`.
## Decision
Keep running until devctl's DB module works; then stop and remove containers, volumes and both compose files — each command shown and confirmed. Data is not migrated.
## Consequences
Frees 3306/5432 for the devctl registry.
