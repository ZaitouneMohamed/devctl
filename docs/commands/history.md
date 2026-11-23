# devctl history

```
devctl history [list] [--limit N] [--actions|--alerts]   # newest last, default 50
devctl --json history                                     # JSON array
devctl history clear                                      # type "history" to confirm
devctl --confirm=history history clear                    # non-interactive (used by the dashboard)
```
Records every state-changing command from the terminal, the dashboard, the timer and git hooks
(secrets masked). File: `~/.local/state/devctl/history.jsonl`. The clear itself is recorded.
Exit codes: 0 · 2 usage · 3 bad --limit · 6 confirmation refused.
