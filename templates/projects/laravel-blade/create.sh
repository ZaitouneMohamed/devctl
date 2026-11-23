# shellcheck shell=bash
# Template laravel-blade: the plain Laravel application skeleton (Blade + Vite + Tailwind).
LARAVEL_PACKAGE=laravel/laravel
LARAVEL_VERSION=^13.0
LARAVEL_FRONTEND=yes
# shellcheck source=templates/projects/_laravel/laravel.sh
source "$DEVCTL_ROOT/templates/projects/_laravel/laravel.sh"
