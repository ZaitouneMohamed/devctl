# ADR-0010: Background checks via an always-on systemd user timer

- Status: Accepted
- Date: 2026-11-05

## Context
Disk warnings, crash notifications and image-update notices must work with no terminal open.
## Decision
`devctl-watch.timer` (user unit, enabled by init after asking) runs `devctl watch tick` every 30 min: disk check; crash and image checks only if Docker is already active; log pruning. Never starts services.
## Consequences
- Explicit, documented exception to "nothing starts at login".
- Very low cost (short one-shot).
