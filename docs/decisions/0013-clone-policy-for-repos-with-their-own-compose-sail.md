# ADR-0013: Clone policy for repos with their own compose/Sail

- Status: Accepted
- Date: 2026-11-05

## Decision
On clone, if `compose.yaml`/`docker-compose.yml` or Sail is detected, ask once: shared services | repo compose as-is | ignore. Store in the site's registry entry; change with `devctl site set`. Never modify repo files. Warn on ports not bound to 127.0.0.1 or conflicting with the registry.
