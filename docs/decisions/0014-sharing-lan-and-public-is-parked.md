# ADR-0014: Sharing (LAN and public) is parked

- Status: Parked
- Date: 2026-11-05

## Context
User postponed all sharing (2026-11-05).
## Decision
Only hook points are designed. Recorded preferences: LAN HTTP by default with `--https` opt-in, 1 h auto-off, Avahi name `zaitoune-laptop.local`; public via swappable tunnel adapter (Cloudflare quick tunnel), password by default, systemd hard time limit.
## Open before unparking
Default firewalld zone `FedoraWorkstation` allows 1025–65535 TCP/UDP inbound; per-site rules are meaningless until that is resolved.
