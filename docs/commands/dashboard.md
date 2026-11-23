# devctl dashboard

```
devctl dashboard [open]   # start if needed, open browser with a one-time login link (desktop icon does this)
devctl dashboard start    # start without opening a browser
devctl dashboard stop
devctl dashboard status   # --json: {"running": true, "port": 7780}
devctl dashboard url      # print a fresh one-time login link (valid 2 minutes, works once)
```
Settings: `dashboard.port` (7780), `dashboard.python` (/usr/bin/python3).
Logs: `journalctl --user -u devctl-dashboard`.
Exit codes: 0 · 5 port in use · 7 not running / Python missing · 9 failed to start.
