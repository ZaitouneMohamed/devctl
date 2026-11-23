# ADR-0012: devctl init is idempotent and rebuilds a fresh machine

- Status: Accepted
- Date: 2026-11-05

## Decision
`devctl init` brings any Fedora machine to the devctl baseline. Each step: check → plan (exact commands) → confirm → apply → verify; done steps are skipped; `--dry-run` supported.
## Consequences
More to build/test up front; same code serves this laptop and a future one.
