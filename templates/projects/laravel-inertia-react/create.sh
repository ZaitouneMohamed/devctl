# shellcheck shell=bash
# Template laravel-inertia-react: Laravel's official React starter kit (Inertia + TypeScript).
# The Laravel installer creates starter-kit projects from the kit's main branch; so does devctl.
LARAVEL_PACKAGE=laravel/react-starter-kit
LARAVEL_VERSION=dev-main
LARAVEL_FRONTEND=yes
# shellcheck source=templates/projects/_laravel/laravel.sh
source "$DEVCTL_ROOT/templates/projects/_laravel/laravel.sh"
