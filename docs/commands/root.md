# devctl root

```
devctl root [status]          # helper + polkit policy: ok | missing | outdated | insecure  (--json)
devctl root install           # shows what and where, asks, then sudo install … (terminal only)
devctl root test              # runs the helper's self-test through sudo
devctl root test --polkit     # same, through pkexec: a desktop password dialog appears
devctl root uninstall         # asks, then sudo rm …
```
Audit log: `journalctl -t devctl-root`. Source of what runs as root: `libexec/devctl-root`.
Exit codes: 0 · 2 usage · 6 declined · 7 no terminal / not installed · 8 refused, cancelled or insecure.
