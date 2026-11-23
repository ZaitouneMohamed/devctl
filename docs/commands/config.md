# devctl config

```
devctl config [show]          # table: SETTING, VALUE, FROM (default | user | env | flag)
devctl config get <setting>   # print one value
devctl config path            # path of your config file
devctl --json config show     # [{"key":…, "value":…, "from":…}]
```

Layers (later wins): `share/defaults.conf` → `~/.config/devctl/devctl.conf` → `DEVCTL_CFG_<KEY>` env → flags.

Your file uses the same syntax as the defaults:

```
# ~/.config/devctl/devctl.conf   (chmod 600)
domain.suffix = test
log.retention_days = 14     # trailing comments are allowed
```

Rules: the file must be yours and not writable by others; every key must exist in
`share/defaults.conf`; values are validated by type and kept literal (no `$VAR`, no `$(…)`).

Exit codes: 0 · 2 usage · 3 invalid value or line · 4 unknown setting (get) · 7 unsafe file.
