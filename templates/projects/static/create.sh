# shellcheck shell=bash
# Template static: copies files/ and fills in the site name.
tpl_create() { # PATH NAME
  run_change --desc "Create project" -- cp -r -- "$DEVCTL_ROOT/templates/projects/static/files" "$1" || return
  ((DEVCTL_DRY_RUN)) && return 0
  sed -i "s/{{NAME}}/$2/g" -- "$1/index.html"
  printf '.DS_Store\n' >"$1/.gitignore"
}
