# ADR-0015: Backups are parked

- Status: Parked
- Date: 2026-11-05

## Decision
Hook points only: `pre-destructive`, `backup.run`, `backup.verify`; `secrets/` path abstracted so it can move into an encrypted, login-unlocked location. Earlier preferences recorded in REQUIREMENTS §3.9.
