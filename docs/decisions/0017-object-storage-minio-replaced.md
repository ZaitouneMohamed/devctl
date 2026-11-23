# ADR-0017: Object storage: MinIO replaced

- Status: Accepted (approved with architecture)
- Date: 2026-11-05

## Context
MinIO stopped community images (Oct 2025) and its repository was archived (Apr 2026).
## Options
RustFS (Apache-2.0, MinIO-compatible API, 1.0 in Sep 2026) · Garage (AGPL-3.0, light) · SeaweedFS (Apache-2.0, admin UI).
## Proposal
RustFS; final decision with versions verified when building the services module.

## Outcome (2026-11-06)
RustFS 1.0.4 implemented (module 13) and verified on real Docker: bucket creation with SigV4, wrong keys rejected, data written under the user's UID.
