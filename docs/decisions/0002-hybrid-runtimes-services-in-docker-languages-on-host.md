# ADR-0002: Hybrid runtimes: services in Docker, languages on host

- Status: Accepted
- Date: 2026-11-05

## Context
Need fast native tooling (IDE, debuggers, Vite) and isolated, versioned services.
## Decision
Databases and services run in Docker. PHP, Composer, Node, Java, Python run on the host, version-pinned per project via standard pin files. A project may opt in to a containerized runtime for old/special versions.
## Consequences
- Native speed and IDE integration; services disposable and versioned.
- devctl must manage version managers and PHP-FPM on the host (ADR-0020, ADR-0021).
