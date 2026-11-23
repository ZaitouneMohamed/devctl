# Module 10 — Language runtimes

Status: built and unit-tested · 2026-11-05 · implements ADR-0002, ADR-0020, ADR-0021

| Runtime | How | Per project | Default |
|---|---|---|---|
| PHP | Fedora `php-fpm` + devctl pool `/etc/php-fpm.d/devctl.conf`: runs **as you**, socket `/run/php-fpm/devctl.sock` (owner caddy, 0660), `pm = ondemand`, errors → `/var/log/php-fpm/devctl-error.log`; validated with `php-fpm -t`, removed if rejected. Still SELinux-confined (`httpd_t`). Other PHP versions: Remi, asked when a project needs one. | `composer.json` | 8.5 (Fedora) |
| Node | fnm **1.39.0, pinned + SHA-256 verified**, https-only download into a private temp folder → `~/.local/bin/fnm`; Node via `fnm install/default` | `.nvmrc`, `.node-version` (fnm switches on `cd`) | 26 LTS (`runtime.node_default`) |
| Java | Fedora `java-25-openjdk-devel` (JDK) | `.java-version` (module 11) | 25 LTS |
| Python | Fedora `uv`; system Python 3.14 | `.python-version`, `pyproject.toml` | 3.14 |

Shell integration: `~/.bashrc.d/devctl.sh` (devctl-owned, 0600, never overwrites a foreign file;
Fedora's `~/.bashrc` reads `~/.bashrc.d`): fnm's `--use-on-cd` hook and
`NODE_EXTRA_CA_CERTS` (Node ignores the system certificate store).

Helper version 6: `php-fpm-setup`, `php-fpm-start`, `php-fpm-stop`. PHP-FPM is not enabled at boot.
Commands: `devctl runtime [status]`, `devctl runtime setup [all|php|node|java|python]`; also a
`devctl init` step. Laravel's PHP extensions were already installed (bcmath, gd, intl, mbstring,
mysqlnd, pdo_pgsql, pdo_sqlite, xml, zip, …).

Tests: 9 bats (`tests/unit/runtime.bats`): status with nothing installed, one combined package
install through the helper, nothing-to-do, usage, checksum mismatch installs nothing, pinned
https URL, shell file safety, helper verb arguments, socket path accepted by the web templates.
Not run for real yet: it installs packages and writes a shell startup file — you run it.
