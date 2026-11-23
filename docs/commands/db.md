# devctl db

```
devctl db [list] [--databases]           devctl db engines
devctl db add ENGINE [--version V] [--any-port]
devctl db create NAME --engine ENGINE [--version V] | --server SERVER
devctl db creds NAME | --server SERVER   (--json for scripts)
devctl db shell NAME                     devctl db root SERVER [--show-key]
devctl db start SERVER                   devctl db stop SERVER [--force]
devctl db export NAME [FILE.gz]          devctl db import NAME FILE[.gz]
devctl db drop NAME                      (delete a database no site uses; type NAME)
devctl db legacy-remove                  (type "legacy" to confirm)
```
TablePlus: host 127.0.0.1, the server's fixed port, user/password from `devctl db creds NAME`.
Exit: 0 · 2 usage · 3 invalid name/version · 4 not found · 5 port busy / in use / exists · 6 declined · 7 needs terminal · 9 engine error.
