# Module 9 — Local names

Status: built and unit-tested · 2026-11-05 · implements ADR-0004

- Desired names: `~/.local/share/devctl/hosts` (one per line), changed by `dns_add`/`dns_remove`.
- `dns_apply` → helper `hosts-apply` only when the list differs from devctl's block.
- Helper: reads the list from the caller's home (system user database), checks every name
  (`label.suffix`, lowercase, ≤ 500 names), rewrites only the block between
  `# >>> devctl managed block` and `# <<< devctl managed block` (127.0.0.1 and ::1 per name),
  keeps every other line byte for byte, backup `/etc/hosts.devctl.bak`, restores the SELinux label.
- `devctl domain [list|apply]` — [docs](../commands/domain.md). Adapter: `lib/adapters/dns/hosts.sh`.
