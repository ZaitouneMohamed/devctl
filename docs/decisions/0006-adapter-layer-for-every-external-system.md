# ADR-0006: Adapter layer for every external system

- Status: Accepted
- Date: 2026-11-05

## Context
Docker may be swapped (Podman installed); web server, DNS, tunnels, runtime managers too.
## Decision
Only adapter files call external tools. Interfaces are documented function sets (e.g. `ce_up`, `ce_exec`, `web_apply`, `dns_add`). Adapter chosen by config key. Arguments always passed as arrays.
## Consequences
- Testable with PATH stubs; swapping = one new file.
- Slight indirection cost in code.
