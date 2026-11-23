# ADR-0001: Repository location and hosting

- Status: Accepted
- Date: 2026-11-05

## Context
devctl needs a home for code and docs. GitHub hosting was undecided.
## Decision
Repo at `~/Desktop/projects/personal/devctl`, local git only (branch `main`). No remote for now.
## Consequences
- Sits with other personal code; runtime data stays in XDG dirs, never in the repo.
- Single copy on an unencrypted, un-backed-up disk until a remote or backups exist. Revisit when `gh` is installed or backups are unparked.
