# ADR-0022: Desktop launcher for the dashboard

- Status: Accepted (Desktop Icons NG v103 installed per user 2026-11-05)
- Date: 2026-11-05

## Context
The user wants an icon on the desktop that opens the dashboard. Stock GNOME 50 shows no icons
on the desktop background; that needs an extension. Neither Desktop Icons NG (`ding@rastersoft.com`)
nor its GTK4 port (`gtk4-ding@smedius.gitlab.com`) is packaged in Fedora 44; both list GNOME 50
support on extensions.gnome.org.

## Decision
- A freedesktop launcher `devctl-dashboard.desktop` (template in `share/desktop/`, absolute path
  to `bin/devctl` filled in at install) plus an SVG icon `devctl` in the user's hicolor theme.
- Installed per user, no sudo: `~/.local/share/applications/` (app grid/search) and `~/Desktop/`
  (executable, `metadata::trusted` so the extension may launch it).
- `install.sh` (module 2) installs and updates it; uninstall removes it.
- The icon runs `devctl dashboard`, which starts the dashboard if needed and opens it in the default browser (module 18a).
- Desktop-icons extension: installed per user via `gnome-extensions install` only after approval.

## Consequences
- With the extension enabled, everything in `~/Desktop` (including the `projects` folder) shows as icons.
- On Wayland a newly installed extension is active only after logging out and back in.
