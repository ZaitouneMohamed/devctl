# Module 5 — init

Status: built and tested · 2026-11-05 · implements [ADR-0012](../decisions/0012-devctl-init-is-idempotent-and-rebuilds-a-fresh-machine.md)

## Purpose
`devctl init` brings this laptop — or a fresh Fedora install after `./install.sh` — to the
devctl baseline. Re-runnable: finished steps are skipped; nothing happens without a "yes".

## Steps (today)
| Step | Check | Apply |
|---|---|---|
| devctl folders | config, data, secrets, registry, state, logs, run, cache exist and are 0700 | `mkdir -p` (umask 077) / `chmod 700` |
| Database data folder | `~/.local/share/devctl/data` is a Btrfs subvolume (inode 256) with `C` attribute | `btrfs subvolume create`, `chattr +C` while empty, `chmod 700` (no root needed) |
| Command, completion, launchers | doctor's `install` check | `devctl self install` |
| Privileged helper | installed and identical to the repo | `devctl root install` (sudo) |
| System settings | doctor's hostname, docker-boot, docker-pools, llmnr, certutil checks | doctor's fixes, each asked separately |

Later modules append steps (runtimes, Caddy + CA trust, background timer).

## Flow
1. Check every step, print ✓ done / → what is missing.
2. One confirmation for the plan; system changes ask again, one by one.
3. Apply in order; re-check each step and report done / still to do.
4. A failing step stops init with how to continue (`devctl init` again).

## Data folder rules (ADR-0008)
- Not Btrfs → a plain folder.
- Btrfs and missing → subvolume + No-CoW.
- Existing **empty** plain folder → replaced by a subvolume.
- Existing **non-empty** folder that is not a No-CoW subvolume → **stop, never touch data**;
  manual migration: stop the databases, `mv data data.old`, run `devctl init`, copy back with
  `cp -a --reflink=never data.old/. data/` (new files inherit No-CoW), then remove `data.old`.

## Design
- Steps are `init_<id>_check` / `init_<id>_apply` pairs; adding a step = two functions + a list entry.
- System settings reuse doctor through a small public interface (`doctor_status_of`,
  `doctor_fixable`, `doctor_title`) — one implementation of each check and fix.
- `--dry-run` resolves the filesystem from the nearest existing folder, so the plan is
  accurate before any folder exists.

## Bash concepts used
- Btrfs facts without root: `stat -f -c %T` (filesystem type), inode 256 (subvolume root),
  `lsattr -d` (`C` = No-CoW). Walking up to the nearest existing parent with `${path%/*}`.
- `umask 077` making every created parent folder private (instead of `mkdir -m`, which only
  applies to the last folder).

## Verified on this laptop (2026-11-05)
Ran for real: folders created 0700; `~/.local/share/devctl/data` is a subvolume (inode 256)
with No-CoW. The helper step needs your terminal (sudo) — run `devctl init` yourself.

## Tests
10 new bats tests (`tests/unit/init.bats`): folders (create, tighten, dry-run), data folder
(non-Btrfs, Btrfs plan + exact dry-run commands, replace empty, refuse non-empty, ok state),
nearest-parent filesystem detection, reuse of doctor checks, CLI dry-run changes nothing.
`make check`: lint + 126 bats + 23 Python — all pass.
