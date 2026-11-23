# ADR-0021: Version managers: fnm, Fedora OpenJDK, uv

- Status: Accepted (approved with architecture)
- Date: 2026-11-05

## Context
Fedora 44 packages Node 20/22/24 only; Node 26 is the current LTS. Java 25 is LTS and packaged; Python 3.15 is newest, 3.14 is the default target.
## Decision
Node via fnm (user-local binary, reads `.nvmrc`/`.node-version`). Java via side-by-side Fedora OpenJDK packages with per-project `JAVA_HOME` (reads `.java-version`, `.sdkmanrc`). Python via uv (Fedora package, reads `.python-version`).
## Consequences
No curl|bash installers (SDKMAN, nvm). Each manager behind a runtime adapter.
