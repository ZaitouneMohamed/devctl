# Module 1 — Core

Status: built, awaiting approval · 2026-11-05

## Purpose

The foundation every other module stands on: one entry point, strict and predictable error
handling, logging with secret redaction, user interaction (colors, confirmations, dry-run),
safe configuration, input validation, locks and an action history. Nothing here knows about
Docker, Caddy or projects.

## Requirements covered

| Requirement (REQUIREMENTS.md) | Where |
|---|---|
| `set -Eeuo pipefail`, traps, cleanup handlers | `errors.sh` |
| Meaningful exit codes | `errors.sh` (`EX_*`) |
| Central logging, 7-day retention | `log.sh` (`log_prune` is called by the timer module later) |
| Secrets never printed or logged | `log_redact`, `history_redact_args` |
| Colored output, `NO_COLOR`, help text | `ui.sh`, `router.sh` |
| `--dry-run` and explicit confirmation | `run_change`, `confirm`, `confirm_typed` |
| Typed confirmation (project name) usable from the dashboard | `confirm_typed` + `--confirm=TEXT` |
| Config-driven behavior, config files | `config.sh`, `share/defaults.conf` |
| Input validation | `validate.sh` |
| History of CLI **and** dashboard actions | `history.sh` + `register_action` in `router.sh` |
| No eval, no unsafe command building | all files; `run_change` takes argv arrays |
| Idempotent, concurrent-safe operations | `lock.sh` |

## Files

```
bin/devctl               entry point: resolve repo through symlinks, source bootstrap, devctl_main
lib/core/bootstrap.sh    HOME check, XDG paths, globals, sources the other core files
lib/core/errors.sh       EX_* codes, die, strict mode, ERR/EXIT/INT/TERM traps, temp files
lib/core/log.sh          log_debug/info/warn/error, redaction, daily file, prune
lib/core/ui.sh           colors, status lines, tables, confirm, confirm_typed
lib/core/json.sh         json_array: safe JSON from shell values (never jq --args)
lib/core/validate.sh     is_* validators, require_valid
lib/core/config.sh       layered config with typed validation
lib/core/lock.sh         flock-based named locks
lib/core/run.sh          run_change (dry-run aware), quote_argv
lib/core/history.sh      JSONL action/alert records
lib/core/router.sh       global flags, dispatch, usage/help, history hook
lib/cmd/{help,version,config}.sh   first commands
share/defaults.conf      every setting with default, comment and @type
```

## Interface (functions other modules use)

| Function | Contract |
|---|---|
| `die CODE MSG` | log error, exit CODE |
| `cleanup_add_fn FN` | run FN at exit (any exit path) |
| `make_temp_file VAR` / `make_temp_dir VAR` | private temp path in VAR, deleted at exit |
| `log_debug/info/warn/error MSG` | diagnostics → stderr (by level) + log file, redacted |
| `ui_step/ok/skip/fail/note/header MSG` | user-facing status lines (stdout; hidden by `--quiet`/`--json`) |
| `ui_plan MSG`, `ui_table` | dry-run plan line; align TSV |
| `confirm Q [yes\|no]` → 0/1 | yes/no; `--yes` and `--dry-run` answer yes; refuses without a TTY |
| `confirm_or_abort Q` | as confirm, exits `EX_ABORTED` on no |
| `confirm_typed TEXT` → 0/1 | must type TEXT; `--yes` never satisfies it; `--confirm=TEXT` does |
| `is_<type> V`, `is_valid TYPE V`, `require_valid TYPE V LABEL` | validation |
| `config_get KEY`, `config_get_bool`, `config_get_path`, `config_origin`, `config_set` | settings |
| `lock_acquire NAME [TIMEOUT]`, `lock_release NAME`, `with_lock NAME -- CMD…` | mutual exclusion |
| `run_change [--desc D] -- CMD ARGS…` | the only way to run a state-changing command |
| `register_action noun.verb…` | mark a command as an action → recorded in history |
| `history_record_alert LEVEL CODE MSG` | record an alert (timer, crash watcher…) |

Exit codes: 0 ok · 1 failure · 2 usage · 3 validation · 4 not found · 5 conflict · 6 aborted · 7 precondition · 8 privilege · 9 external tool.

## Commands added

- [`devctl help`](../commands/help.md)
- [`devctl version`](../commands/version.md)
- [`devctl config`](../commands/config.md)

## Bash concepts used

- **Strict mode** — `set -E` (ERR trap inherited by functions), `-e` (exit on unhandled failure),
  `-u` (unset variables are errors), `-o pipefail` (a pipeline fails if any part fails),
  `shopt -s inherit_errexit` (command substitutions `$(…)` also exit on failure).
- **Traps** — `ERR` logs the failing command and a stack (`FUNCNAME`, `BASH_SOURCE`,
  `BASH_LINENO`); `EXIT` runs cleanup on every exit path; `INT`/`TERM` turn Ctrl+C/kill into
  exit codes 130/143 so cleanup still runs.
- **errexit pitfalls** — errexit is disabled inside anything on the left of `||`/`&&` or in an
  `if` condition, *including functions called there*. That is why `with_lock` and `run_change`
  capture `status=$?` explicitly and document it.
- **Namerefs** (`local -n`) — `make_temp_file VAR` writes into the caller's variable. Returning
  the path with `$(…)` would run the function in a subshell and lose the cleanup registration.
- **Associative arrays** (`declare -gA`) — config values, origins and types; validator table;
  lock file descriptors.
- **Automatic file descriptors** — `exec {fd}>>file` lets Bash pick a free fd for `flock`;
  the kernel drops the lock when the process dies, even on `kill -9`.
- **`printf '%(fmt)T' -1`** — dates without forking `date`; `EPOCHREALTIME` for microsecond timing
  (its decimal separator depends on locale, so both `.` and `,` are stripped).
- **`printf %q`** — quoting argv for *display only*; commands themselves are run as `"$@"`, never
  rebuilt as a string, so `;`, spaces or `$(…)` in data can never execute.
- **Safe parsing** — the config reader uses `[[ =~ ]]` and `BASH_REMATCH`, never `source`/`eval`,
  so values like `$(rm -rf ~)` stay literal text.
- **Parameter expansion** — trimming whitespace (`${v#"${v%%[![:space:]]*}"}`), case conversion
  (`${v,,}`, `${v^^}`), substitution (`${v//./_}`), indirect expansion (`${!var}`).
- **Double-source guards** — `[[ -n ${__X:-} ]] && return 0` lets files be sourced in any order.
- **`readlink -f "${BASH_SOURCE[0]}"`** — finds the real repo through the `~/.local/bin` symlink,
  so code is never loaded from `$PWD`.
- **umask 077** — every file devctl creates (logs, history, locks) is private by default.

## Design choices inside the module

- **log vs ui**: `log_*` = diagnostics (stderr; only warnings/errors by default, `--verbose` shows
  all; the file always gets info+). `ui_*` = conversation with you (stdout).
- **Global flags anywhere** before `--`: `devctl site delete shop --dry-run` works. Global flag
  names are therefore reserved and not used by individual commands.
- **Config**: every key must exist in `defaults.conf`, with a `# @type` line, so a typo in your
  config is reported, and invalid values fail early with the file and line number.
  Env overrides use the `DEVCTL_CFG_` prefix so they can never collide with internal variables.
  Runtime switches (`--yes`, `--dry-run`) are **not** read from the environment.
- **History** records only commands marked with `register_action`, so `status`/`list` do not
  flood it. Recording happens in the EXIT trap, so failures and Ctrl+C are recorded too.
  It is best-effort: if the file can't be written you get a warning, the command still runs.
- **Dry-run** answers yes to confirmations so the plan shows every step, but never executes
  anything passed through `run_change`.

## Edge cases handled

| Case | Behavior |
|---|---|
| Empty or relative `$HOME` | refuse to run (exit 7) |
| Relative `XDG_*` variables | ignored, as the XDG spec requires |
| Run through a symlink | repo found via `readlink -f` |
| Unknown command, `../etc/passwd` as command | exit 2; names are validated before any file lookup |
| Config file writable by others / not yours | refuse with the exact `chmod` fix (exit 7) |
| Malformed config line | exit 3 with `file:line` |
| CRLF line endings, missing final newline, quotes, trailing comments | handled |
| Unknown setting in your file | warning, ignored |
| `$(…)`, `${HOME}` in config values | stay literal |
| No terminal for a confirmation | exit 7 with a hint (`--yes` / `--confirm=`) |
| `--yes` with a typed confirmation | not enough; typed text required |
| Log or history file unwritable | one warning, command continues |
| Second devctl run on the same lock | waits up to `lock.timeout_seconds`, then exit 5 |
| Crash or Ctrl+C | temp files removed, history records the exit code |
| Secrets in messages or args (`--password x`, `--x-token=y`, `KEY=…`, `user:pass@host`) | masked as `****` |

## Tests

`make check` = `make lint` (ShellCheck 0.11, whole program from `bin/devctl` + each core file for parse errors) + `make test` (63 bats tests in `tests/unit/`) + `make test-dashboard` (23 Python tests).
Status 2026-11-05: all pass. Bugs the tooling caught and fixed: jq `--args` dropping history records whose arguments start with `--`; a misplaced ShellCheck directive that made ShellCheck silently skip `config.sh`; `mkdir -p -m 700` leaving parent folders with default permissions (now `ensure_private_dir`).

`make test` runs `tests/unit/*.bats`. Each test gets an empty private
`HOME`; nothing touches your real config or the system. `tests/unit/cli.bats` builds a sandbox
copy of the repo to add fake commands (history recording, cleanup on failure, typed confirm).
