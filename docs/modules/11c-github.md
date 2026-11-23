# Module 11c — GitHub

Status: built and tested · 2026-11-06

## Commands — [docs](../commands/github.md)
- `devctl github [status]` — gh installed, signed in (as whom), git name/email.
- `devctl github setup` — installs `gh` (Fedora package, helper allow-list), `gh auth login --web`
  (one-time code in your terminal, sign-in in your browser), then `gh auth setup-git` so plain
  `git` over HTTPS uses that sign-in (private repositories, pull/push).
- `devctl github repos [--owner X] [--limit N]` — your repositories and your organisations',
  newest push first (`--json` for the dashboard).
- `devctl site clone OWNER/REPO|URL [--name N] [--category C]` — OWNER/REPO means GitHub; cloned
  with `gh repo clone` when signed in, else `git clone`.

## Detection of cloned projects
| Found | Kind | Then |
|---|---|---|
| `composer.json` requiring `laravel/framework` | laravel | PHP-FPM site, Vite port, dependencies asked |
| `pom.xml` with spring-boot / Gradle with `org.springframework.boot` | proxy (spring-boot) | app port 81xx, `devctl site dev` (mvnw or gradlew; `devctl.env` git-excluded) |
| `src/**/*.java` without a build tool | none (java) | `devctl site dev` compiles and runs |
| `index.html` | static | served as is |
Anything else: cloned but not set up (clear message). Verified on real repositories:
laravel/laravel, spring-projects/spring-petclinic, mdn/beginner-html-site-styled, plain sources.

## Dashboard
Sites page → **Clone from GitHub…**: repository picker (yours + organisations', private marked),
optional name, category. Not signed in → tells you to run `devctl github setup` (needs a terminal).
Inputs are shape-checked (OWNER/REPO only); devctl validates again.

## Doctor
New checks: git name/email (reported only; your choice), GitHub sign-in (fix: `devctl github setup`).

## Tests
`tests/unit/github.bats` (7, fake gh): repository listing and order, signed-out message, status,
OWNER/REPO and URL validation (rejects `;`, `file://`, option-like input), detection of every kind,
gh vs git clone choice, derived names. Dashboard: clone endpoint and unsafe repository input.

## Dashboard Setup page (2026-11-06)
New **Setup** page (sidebar). GitHub card: Install GitHub CLI (desktop password dialog),
**Sign in with GitHub** (device flow: the page shows the one-time code with Copy and an
"Open GitHub" link; you approve on github.com — no password through the page), or a personal
access token (GitHub refuses account passwords for git since 2021; the token is checked for
shape, sent to `devctl github login --with-token` on stdin — never in arguments, logs or
history — and stored by gh in the system keyring), Sign out (type "github"). Git identity card:
name and email → `devctl github identity` (git config --global).
New CLI: `devctl github install | login [--with-token] | logout | identity --name --email`.
Tests: token never in argv/logs/history (bats), endpoints and input checks (Python).

## Databases for cloned projects (2026-11-06, ADR-0024)
`devctl site clone … [--db auto|ENGINE|none] [--fill migrate|import|none] [--file PATH]` and
`devctl site db NAME [--engine …] [--fill …] [--file …]`: engine guessed from the project and
confirmed, database + user created (or reused), connection written into `.env` / `devctl.env`,
then filled as chosen. Dashboard: Clone form has Database + Fill (with a dump upload and a real
progress bar); each Laravel/Spring site row has "Database…". Tests: `tests/unit/sitedb.bats` (9),
upload and option tests in Python (incl. a path-traversal regression test).
