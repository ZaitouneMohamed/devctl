# ADR-0024: Cloned projects always get a database; filling it is asked

- Status: Accepted
- Date: 2026-11-06
- Supersedes part of REQUIREMENTS §3.1 ("cloned project: … I handle .env, database and migrations myself")

## Context
Wiring a cloned project to a database by hand (`db create`, `db creds`, editing `.env`) is
repetitive and error-prone. The user wants it always set up, but to choose each time how the
database is filled: sometimes from the project's migrations, sometimes from existing tables (a dump).

## Decision
After cloning a Laravel or Spring Boot project, devctl:
1. guesses the engine (Laravel `.env.example` DB_CONNECTION; Spring JDBC driver) and lets you
   confirm or change it (or choose none);
2. creates the database and a least-privilege user (reused if it exists);
3. writes the connection: Laravel `.env` (from `.env.example` if missing, 0600, APP_URL,
   DB_*, APP_KEY generated when dependencies are installed); Spring `devctl.env` (git-excluded);
4. asks how to fill it: **migrate**, **import a dump** (.sql/.sql.gz/.dump/.archive; PostgreSQL
   plain SQL runs as the project user) or **leave it empty**.
The same is available for any existing site: `devctl site db NAME` and the dashboard's
"Database…" button. Dashboard dumps are uploaded to `run/uploads/` (0600, random names, deleted
after a day); the browser never passes a file path.

## Consequences
- Non-interactive runs use the guess and migrations unless `--db/--fill/--file` say otherwise.
- A path-traversal bug in the first version of the upload code was caught by tests and fixed
  (the stored name is now random hex + an allow-listed extension).

## Shared databases (2026-11-11)
A site can use a database another site already uses: `devctl site create … --use-db DB`,
`devctl site clone … --use-db DB`, `devctl site db NAME --use DB`; dashboard: "Existing
databases" in every Database choice. The site gets that database's own user and password
(same `DB_*`). Its tables are left as they are: fill defaults to "leave as is", template
migrations are skipped, and Spring Boot gets `SPRING_JPA_HIBERNATE_DDL_AUTO=none` so Hibernate
never alters the shared schema. Deleting a site never deletes a database, shared or not.
