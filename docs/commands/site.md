# devctl site

```
devctl site [list]                                   devctl site info NAME
devctl site create NAME [--category C] [--db ENGINE] devctl site clone URL [--name N] [--category C]
devctl site start|stop NAME                          devctl site dev NAME   (Vite, Ctrl+C stops)
devctl site open NAME                                devctl site delete NAME [--with-db|--keep-db] (type NAME)
```
Engines for the Laravel template: mysql, postgres, mariadb, sqlite.
