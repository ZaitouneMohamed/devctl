# ADR-0020: PHP: Fedora php-fpm, Remi SCL only on demand

- Status: Accepted (approved with architecture)
- Date: 2026-11-05

## Context
Fedora 44 ships PHP 8.5.12 (newest). Remi supports Fedora 44 with parallel SCL packages (`php84`, `php85`, …).
## Decision
Default PHP 8.5 from Fedora. When a project needs another version, ask to add Remi and install that version's `phpXY-php-fpm` side by side. One FPM master per version, pools run as the user, sockets in `/run/devctl/`.

## Implementation (2026-11-11)
Triggered by domi-api (phpoffice/phpspreadsheet 1.30.5 requires PHP < 8.5). The user chose Remi.
- `devctl runtime php add 8.4`: helper `remi-enable` (Fedora 44 only; downloads
  remi-release-44.rpm, **SHA-256 pinned** because the package is unsigned; trusts its signing key
  only if the fingerprint is `2E37 5FE2 4EDF F0F2 E0D8 E165 ED5B 58C5 BEFA 00E2`, cross-checked with
  Remi's KEYS.txt "2026 key used for Fedora 44-45"; otherwise removes it), then
  `php-version-install 8.4` (php84-php-{cli,fpm,bcmath,gd,intl,mbstring,mysqlnd,opcache,pdo,pecl-zip,pgsql,process,sodium,xml})
  and `php-fpm-setup 8.4`.
- SELinux: Fedora's policy does not label Remi's paths (verified with matchpathcon: bin_t/usr_t),
  so the helper adds fcontexts: php-fpm → httpd_exec_t, run → httpd_var_run_t, log → httpd_log_t.
- Each Laravel site records `php_version`; Caddy uses that version's socket
  (`/var/opt/remi/php84/run/php-fpm/devctl.sock`); Composer/artisan run with `/usr/bin/php84`.
- Clones pick the newest installed PHP whose `composer check-platform-reqs --lock` passes.
- Commands: `devctl runtime php [list|add V]`, `devctl site php NAME [V]`, `devctl site deps NAME`.
- Also added: `php-sodium` (needed by lcobucci/jwt) to the PHP setup.
