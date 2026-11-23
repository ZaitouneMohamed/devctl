# Module 4 — Doctor

Status: built and tested · 2026-11-05

## Purpose
`devctl doctor` checks this laptop for the problems found in the Phase 0 audit and every
requirement devctl relies on, and offers a fix for each — asking before every one.

## Checks
| Check | ok when | Fix offered (needs) |
|---|---|---|
| devctl installed | `devctl self status` all ok | `devctl self install` |
| Privileged helper | installed, root-owned, matches repo | `devctl root install` (sudo) |
| SELinux | Enforcing | none — never changed by devctl; manual hint |
| Hostname | static = `system.hostname` (zaitoune-laptop) | `hostname-set` (helper) |
| Docker at boot | docker.service and docker.socket not enabled | `docker-boot-disable` (helper) |
| Docker address pools | `/etc/docker/daemon.json` pins pools | create it with 172.20.0.0/14 /24 (helper; only if absent) |
| Network overlaps | no two interface networks overlap (LAN, vmnet, Docker) | — (report) |
| Ports 80/443 | free, or used by Caddy | — (report) |
| LLMNR | disabled globally | `llmnr-disable`: resolved drop-in `LLMNR=no` + restart resolved (helper) |
| Open to the network | nothing on 0.0.0.0/[::] (LLMNR excluded) | — info + `sudo ss -ltnp` |
| certutil | `certutil` present | `pkg-install nss-tools` (helper) |
| Firewall | default zone has no 1025-65535 range | — info (sharing parked) |
| Disk space | free > `guard.disk_min_free_percent` | — |
| Disk encryption | a `crypt` device exists | — info (your decision) |
| Avahi | active | — info |
| Old DB containers | none of dev-mysql/dev-postgres | — info (ADR-0016) |

Result on this laptop (2026-11-05): 6 warnings (helper, hostname, Docker at boot, Docker
pools, LLMNR, certutil), all fixable; info: port 27500 open on all interfaces, firewall
range, no encryption, old DB containers.

## New helper verbs (helper version 2)
`hostname-set NAME`, `docker-boot-disable`, `docker-address-pools` (refuses if daemon.json
exists), `llmnr-disable`, `pkg-install PKG…` (allow-list: nss-tools caddy php-fpm uv gh
java-25-openjdk-devel; Fedora repos only), `listeners` (read-only `ss -ltnp`).
New setting: `system.hostname` (type `hostname`).

## Design
- Checks only **read** (through `probe_*` functions); fixes are separate functions.
- A check that crashes becomes "info: could not run" — doctor never aborts halfway.
- Fixes run in order; each is re-checked afterwards and reported ✓ or still !.
  Fixes needing the helper are skipped (with the reason) until it is installed.
- `--check` / `--json` never fix (for the dashboard and the timer).
- `--dry-run` shows the exact commands, including the sudo ones.
- Applying any fix records `doctor.fix` in history (`router_mark_action`).
- Exit 0 = no problems, 1 = problems remain.

## Bash concepts used
- IPv4 math in Bash: dotted quad → integer with shifts, prefix masks
  `(0xFFFFFFFF << (32-n)) & 0xFFFFFFFF`, overlap = equal under the shorter mask.
- Dispatch by name: `"doctor_check_${id//-/_}"`; per-check result in globals.
- Overriding functions in tests to fake the machine (probes).

## Tests
22 new bats tests (`tests/unit/doctor.bats`): every check's ok and problem paths with fake
probes, CIDR overlap math, crash isolation, fix flow (skip without helper, declined,
accepted + re-check), JSON output on the real machine, helper verb validation (hostname,
package allow-list, no stray arguments). `make check`: lint + 116 bats + 23 Python — pass.
Not testable without your password: the fixes themselves (they run as root).
