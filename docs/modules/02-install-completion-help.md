# Module 2 — Install, Tab completion, help

Status: built, awaiting approval · 2026-11-05

## Purpose
Make devctl usable as a plain `devctl` command with Tab completion and helpful errors,
installed and removed safely for the user only (no sudo).

## What was added
| Piece | Where |
|---|---|
| `./install.sh` → `devctl self install` | `install.sh`, `lib/cmd/self.sh` |
| `devctl self [status\|install\|uninstall]` | `lib/cmd/self.sh` — [docs](../commands/self.md) |
| Bash Tab completion | `share/completions/devctl.bash` + hidden `devctl complete` (`lib/cmd/complete.sh`) |
| "did you mean" for mistyped commands and subcommands | `router__suggest`, `router__distance` (Levenshtein ≤ 2 or prefix) |
| Hidden commands (`# hidden: yes` header) | `router_commands` |
| Conditional actions in history (`router_mark_action`) | `router.sh`; used by `dashboard open` when it starts the server |
| Launcher marker `X-Devctl-Managed=true` | `share/desktop/devctl-dashboard.desktop.in` |
| Setting `self.desktop_icon` | `share/defaults.conf` |

## Installed items
| Item | Path | Kind |
|---|---|---|
| command | `~/.local/bin/devctl` | symlink → `bin/devctl` |
| completion | `~/.local/share/bash-completion/completions/devctl` | symlink → `share/completions/devctl.bash` |
| icon | `~/.local/share/icons/hicolor/scalable/apps/devctl.svg` | symlink → `share/icons/devctl.svg` |
| app-launcher | `~/.local/share/applications/devctl-dashboard.desktop` | generated (absolute repo path) |
| desktop-icon | `~/Desktop/devctl-dashboard.desktop` (from `user-dirs.dirs`) | generated, 755, `metadata::trusted` |

Symlinks mean a `git pull`/edit in the repo is live immediately; only the launchers embed
the repo path, so moving the repo needs `./install.sh` again.

## How completion works
`_devctl` (Bash) calls `devctl complete -- <words>`; devctl answers from its own command
files, so completion can never drift from the real commands. Commands extend it with an
optional `complete_<noun> flags|args VERB [N]` function (e.g. `config get <TAB>` → setting
names). Global flags complete anywhere; `--color=<TAB>` offers values; `=` word-breaking
and `~/…` paths are handled. Cost: one devctl run per Tab press (~50 ms).

## Safety
- State per item: `ok`, `missing`, `outdated` (devctl's own file → updated), `conflict`
  (someone else's file → never touched; exit 5 after installing everything else).
- `--force` asks first and keeps `<file>.devctl-backup`.
- Uninstall removes only items devctl made (marker / link into the repo / identical copy),
  asks first, and keeps config, history, logs and the repo.
- Everything goes through `run_change`, so `--dry-run` shows the exact `ln`/`install`/`gio`
  commands and changes nothing.
- The launcher's repo path must match `^[A-Za-z0-9/._+-]+$` (desktop-entry Exec quoting).

## Bash concepts used
- **Programmable completion**: `complete -F`, `COMP_WORDS`/`COMP_CWORD`, `COMPREPLY`,
  `compopt -o nospace`, bash-completion's `_init_completion -n =`, `COMP_WORDBREAKS`.
- **`${!#}`** (last positional argument) and array slices `"${@:1:$#-1}"`.
- **`mapfile -O`** to append command output to an existing array.
- **`declare -F`** to discover functions (subcommands) at runtime.
- **Dynamic programming in Bash** (Levenshtein) with indexed arrays and `$(( ))`.
- **`ln -sfT`**: replace atomically, never descend into a directory named like the target.
- **`readlink`** (not `-f`) to compare a symlink's literal target.
- **Parsing `user-dirs.dirs` without `eval`** (`$HOME` substituted with `${v/#\$HOME/$HOME}`).

## Edge cases
| Case | Behavior |
|---|---|
| Run twice | everything `already installed`, nothing changed |
| Files from the earlier hand install (module 18a) | recognised as devctl's (`outdated`) and updated |
| A foreign `~/.local/bin/devctl` | left alone, other items installed, exit 5 with hint |
| Desktop folder renamed/localised (e.g. `~/Bureau`) | taken from `user-dirs.dirs` |
| `self.desktop_icon = false` | no desktop launcher (app grid launcher still installed) |
| `~/.local/bin` not on PATH | note with the exact line for `~/.bashrc` |
| No `gio` / cache tools | skipped; note to use "Allow Launching" |
| Uninstall without a terminal | refuses (exit 7) unless `--yes` |
| `devctl dashboard stp` (typo of a subcommand of a command with a default action) | suggestion instead of passing `stp` as an argument |
| A command file listed and dispatched in one run | loaded once (`__ROUTER_LOADED`) |

## Tests
`make check`: ShellCheck (now also `install.sh` and the completion script) + 82 bats tests
(new: `tests/unit/complete.bats`, `tests/unit/self.bats`, suggestions/hidden/mark-action in
`cli.bats`) + 23 Python tests. All pass (2026-11-05). External tools (`gio`, cache updaters)
are replaced by logging stubs; every test uses a private temporary HOME.

Real install on this laptop: `./install.sh` → all 5 items `ok`; `devctl` resolves to
`~/.local/bin/devctl` in a new shell and `complete -p devctl` shows `_devctl`.
