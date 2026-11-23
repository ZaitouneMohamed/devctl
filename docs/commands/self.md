# devctl self

```
devctl self [status]                               # ITEM / STATE / PATH  (--json available)
devctl self install [--force] [--no-desktop-icon]  # same as ./install.sh
devctl self uninstall                              # asks first; keeps config, history, logs, repo
```
States: `ok` · `missing` · `outdated` (devctl's own file, will be updated) · `conflict` (not devctl's; never replaced without `--force`).
Setting: `self.desktop_icon` (default true).
Exit codes: 0 · 2 usage · 5 conflict left in place · 6 declined · 7 no terminal for a confirmation · 9 a file operation failed.
