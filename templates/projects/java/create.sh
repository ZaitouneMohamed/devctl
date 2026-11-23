# shellcheck shell=bash
# Template java: src/Main.java, .java-version; run with the source launcher (no build tool).
tpl_create() { # PATH NAME
  run_change --desc "Create project" -- cp -r -- "$DEVCTL_ROOT/templates/projects/java/files" "$1" || return
  ((DEVCTL_DRY_RUN)) && return 0
  sed -i "s/{{NAME}}/$2/g" -- "$1/src/Main.java"
  printf '%s\n' "$(config_get runtime.java_default)" >"$1/.java-version"
  printf 'out/\n*.class\n' >"$1/.gitignore"
}

# Compile everything in src/ and run Main (Ctrl+C stops it).
tpl_dev() { # PATH NAME
  local path=$1
  local -a sources=()
  mapfile -t sources < <(find "$path/src" -name '*.java' | sort)
  ((${#sources[@]})) || die "$EX_NOTFOUND" "no .java files in $path/src"
  # javac does not accept "--"; the paths are absolute, so none can look like an option.
  site__java "$path" javac -d "$path/out" "${sources[@]}" || die "$EX_EXTERNAL" "compilation failed"
  site__java "$path" java -cp "$path/out" Main
}
