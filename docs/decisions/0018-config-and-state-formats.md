# ADR-0018: Config and state formats

- Status: Accepted
- Date: 2026-11-05

## Decision
User config: `key = value` text parsed by a strict reader (no `source`, no `eval`, no expansion). Machine state: TSV registries + per-site `.conf`, written atomically under `flock`. History: JSON Lines built with `jq --arg`. SQLite only inside the dashboard as an index.
## Consequences
Greppable, diffable, safe to parse in Bash; `jq` is a required dependency (already installed).
