# ADR-0019: Single privileged helper via sudo and pkexec

- Status: Accepted
- Date: 2026-11-05

## Decision
`/usr/local/libexec/devctl-root` (root-owned) accepts a fixed verb list, validates all arguments against allow-lists and fixed path prefixes, uses no shell evaluation. CLI calls it with `sudo` (password), dashboard with `pkexec` (polkit `auth_admin`, GNOME password dialog). No NOPASSWD rules.
## Implementation (module 3, 2026-11-05)
- polkit action `local.devctl.root`, `auth_admin`, `exec.path` = `/usr/local/libexec/devctl-root`.
- The helper refuses to run unless EUID 0, a non-root caller (`SUDO_UID`/`PKEXEC_UID`) and it is the root-owned installed copy; devctl refuses an installed copy that differs from the repo ("outdated").

## Consequences
Small audited root surface; the helper must be reinstalled (with consent) when it changes.
