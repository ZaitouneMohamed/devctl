# devctl doctor

```
devctl doctor              # check, then offer each fix (asks every time)
devctl doctor --check      # check only
devctl --json doctor       # [{"id","title","status","message","fix"}] (check only)
devctl --dry-run doctor    # show the exact commands fixes would run
```
Symbols: ✓ ok · ! warning · ✗ problem · i information. Exit: 0 no problems · 1 problems remain.
