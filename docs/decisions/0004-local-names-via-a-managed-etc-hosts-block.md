# ADR-0004: Local names via a managed /etc/hosts block

- Status: Accepted
- Date: 2026-11-05

## Context
`.test` names must resolve locally; one name per project, no subdomains.
## Decision
Explicit entries (127.0.0.1 and ::1) inside a marked block in `/etc/hosts`, rewritten atomically by the privileged helper after line-by-line validation. No dnsmasq or resolved stub-zone.
## Consequences
- No resolver changes, works with systemd-resolved and nsswitch `files` first.
- Requires sudo per add/remove (acceptable; one prompt).
- Behind the `dns` adapter; wildcard DNS can replace it later.
