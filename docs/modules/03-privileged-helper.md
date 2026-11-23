# Module 3 — Privileged helper

Status: built, awaiting approval · 2026-11-05 · implements [ADR-0019](../decisions/0019-single-privileged-helper-via-sudo-and-pkexec.md)

## Purpose
One small, auditable, root-owned script is the only thing in devctl that runs as root.
Later modules (hosts, Caddy, SELinux, Docker, hostname, CA trust) add verbs to it.

## Pieces
| Piece | Where |
|---|---|
| Helper (runs as root) | `libexec/devctl-root` → installed to `/usr/local/libexec/devctl-root` (root:root 0755) |
| polkit policy (dashboard password dialog) | `share/polkit/local.devctl.root.policy` → `/usr/share/polkit-1/actions/` (0644) |
| How devctl calls it | `lib/core/privilege.sh`: `priv_run`, `priv_helper_state` |
| Command | `devctl root [status\|install\|test [--polkit]\|uninstall]` — [docs](../commands/root.md) |

Verbs today: `version`, `self-test`. Each later module adds its own verbs with validation and tests.

## How a privileged call works
```
devctl site create shop                       (later modules)
  └─ priv_run hosts-apply …                    lib/core/privilege.sh
       ├─ helper state must be ok (root-owned, not writable by others, identical to the repo copy)
       ├─ terminal  → sudo   -- /usr/local/libexec/devctl-root VERB ARGS   (password prompt)
       └─ dashboard → pkexec -- /usr/local/libexec/devctl-root VERB ARGS   (GNOME password dialog)
            └─ helper: EUID 0? real caller via SUDO_UID/PKEXEC_UID (not root)? running from
               /usr/local/libexec, root-owned? → fixed verb list → validated args → journal
```

## Security properties
- **Root-owned and outside your home**: a compromised user process cannot change what
  runs as root after you type the password. The helper checks this about itself.
- **Self-contained**: never sources files from the repo; fixed `PATH` and `LC_ALL`; no `eval`
  (a test checks there is no eval/source).
- **Fixed verbs, validated arguments**: unknown verbs → exit 64; refusals → exit 77.
- **Audit trail**: every call, allowed or refused, logged with the caller's uid:
  `journalctl -t devctl-root`.
- **No passwordless rules**: sudo asks for the password (sudo's usual 5-minute cache applies);
  polkit `auth_admin` asks every time.
- **Drift detection**: if the repo copy changes, devctl refuses to use the installed helper
  ("outdated") until `devctl root install` updates it — so you always review what changed.
- **SELinux**: `install -Z` gives the files the labels their destination expects.

## Bash concepts used
- `"${BASH_SOURCE[0]}" == "$0"` guard: the file runs `main` only when executed, so tests can
  load its functions.
- `sysexits.h` codes (64 usage, 77 no permission) to tell "refused" from "failed".
- `stat -c '%u %a'` + octal arithmetic `8#$mode & 8#022` for permission checks.
- `${verb//[^a-z0-9-]/?}` to sanitise untrusted text before logging it.
- Mapping launcher exit codes (pkexec 126 = dialog dismissed, 127 = not authorised).

## Edge cases
| Case | Behavior |
|---|---|
| Helper not installed / outdated | devctl stops with the exact fix: `devctl root install` (exit 7) |
| Helper not owned by root / writable by others | refused, never run (exit 8) |
| Helper run directly, or from the repo | refuses itself (exit 77) |
| sudo needs a password but there is no terminal | clear error (exit 8) instead of hanging |
| Password dialog cancelled | "authentication was cancelled" (exit 8) |
| `--dry-run` | prints the exact `sudo -- /usr/local/libexec/devctl-root …` line, runs nothing |
| Error raised inside `$(…)` | reported once (fixed a duplicate "unexpected failure" line) |

## Tests
14 new bats tests (`tests/unit/privilege.bats`): helper refusals, caller detection, no eval,
policy XML, helper states, sudo vs pkexec choice, dry-run, exit-code mapping, no-terminal.
sudo/pkexec are replaced by logging stubs. `make check`: lint + 96 bats + 23 Python — all pass.

**Not verifiable without your password**: the real install and the real sudo/pkexec runs —
done by you with `devctl root install`, `devctl root test` and `devctl root test --polkit`.
