# Architecture Decision Records

Format: Context · Decision · Consequences. Superseded ADRs are kept and marked.

- [ADR-0001](0001-repository-location-and-hosting.md) Repository location and hosting — Accepted
- [ADR-0002](0002-hybrid-runtimes-services-in-docker-languages-on-host.md) Hybrid runtimes: services in Docker, languages on host — Accepted
- [ADR-0003](0003-caddy-as-the-single-front-door.md) Caddy as the single front door — Accepted
- [ADR-0004](0004-local-names-via-a-managed-etc-hosts-block.md) Local names via a managed /etc/hosts block — Accepted
- [ADR-0005](0005-https-by-default-with-caddy-local-ca-vite-hmr-via-per-site-tls-port.md) HTTPS by default with Caddy local CA; Vite HMR via per-site TLS port — Accepted
- [ADR-0006](0006-adapter-layer-for-every-external-system.md) Adapter layer for every external system — Accepted
- [ADR-0007](0007-db-topology-port-registry-and-least-privilege-users.md) DB topology, port registry and least-privilege users — Accepted
- [ADR-0008](0008-db-data-in-a-no-cow-btrfs-subvolume-under-local-share.md) DB data in a No-CoW Btrfs subvolume under ~/.local/share — Accepted
- [ADR-0009](0009-dashboard-python-stdlib-cli-as-the-only-actor-dashboard-processes-as-transient-user-units.md) Dashboard: Python stdlib, CLI as the only actor; dashboard processes as transient user units — Accepted
- [ADR-0010](0010-background-checks-via-an-always-on-systemd-user-timer.md) Background checks via an always-on systemd user timer — Accepted
- [ADR-0011](0011-interactive-menu-in-pure-bash-fzf-optional.md) Interactive menu in pure Bash, fzf optional — Accepted
- [ADR-0012](0012-devctl-init-is-idempotent-and-rebuilds-a-fresh-machine.md) devctl init is idempotent and rebuilds a fresh machine — Accepted
- [ADR-0013](0013-clone-policy-for-repos-with-their-own-compose-sail.md) Clone policy for repos with their own compose/Sail — Accepted
- [ADR-0014](0014-sharing-lan-and-public-is-parked.md) Sharing (LAN and public) is parked — Parked
- [ADR-0015](0015-backups-are-parked.md) Backups are parked — Parked
- [ADR-0016](0016-discard-legacy-mysql-postgres-compose-setup.md) Discard legacy MySQL/Postgres compose setup — Accepted
- [ADR-0017](0017-object-storage-minio-replaced.md) Object storage: MinIO replaced — Accepted
- [ADR-0018](0018-config-and-state-formats.md) Config and state formats — Accepted
- [ADR-0019](0019-single-privileged-helper-via-sudo-and-pkexec.md) Single privileged helper via sudo and pkexec — Accepted
- [ADR-0020](0020-php-fedora-php-fpm-remi-scl-only-on-demand.md) PHP: Fedora php-fpm, Remi SCL only on demand — Accepted
- [ADR-0021](0021-version-managers-fnm-fedora-openjdk-uv.md) Version managers: fnm, Fedora OpenJDK, uv — Accepted
- [ADR-0022](0022-desktop-launcher-for-the-dashboard.md) Desktop launcher for the dashboard — Accepted
- [ADR-0024](0024-clones-always-get-a-database.md) Cloned projects always get a database; filling it is asked — Accepted
- [ADR-0023](0023-caddy-confined-as-httpd-with-acls.md) Caddy confined by SELinux, user caddy, read-only ACLs — Accepted
