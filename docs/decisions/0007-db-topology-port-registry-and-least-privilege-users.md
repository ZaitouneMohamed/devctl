# ADR-0007: DB topology, port registry and least-privilege users

- Status: Accepted
- Date: 2026-11-05

## Context
Many projects, shared servers, GUI connections must never break.
## Decision
One shared server per engine+major (`<engine>-<major>`), dedicated `<engine>-<major>-<project>` on request. Host port allocated once (engine default upward), recorded in the registry, never changed or reused. Per-project users limited to their DB; root creds only in devctl's secrets dir. Servers start on demand with refcounting.
## Consequences
- Stable TablePlus connections; low RAM use.
- Shared servers mean a crash affects several projects (acceptable for dev).
