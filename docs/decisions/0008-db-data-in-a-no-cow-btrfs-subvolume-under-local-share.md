# ADR-0008: DB data in a No-CoW Btrfs subvolume under ~/.local/share

- Status: Accepted
- Date: 2026-11-05

## Context
Btrfs CoW fragments DB files; data must not live under ~/Desktop.
## Decision
`~/.local/share/devctl/data` is its own Btrfs subvolume with `chattr +C` set while empty; one subdir per server inherits it; bind-mounted with `:Z`.
## Consequences
- No compression/checksums on DB files (normal for databases).
- Excluded from home snapshots; easy to size and back up later.
- Files are owned by container UIDs → removal goes through devctl/the container, not `rm`.
