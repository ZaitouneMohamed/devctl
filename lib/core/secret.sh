# shellcheck shell=bash
# secret.sh — generated passwords and private credential files (0600, in 0700 folders).
# Values are never logged: callers pass them only through files, stdin or environment
# variables, never as command-line arguments (those are visible to every user via ps).

[[ -n ${__DEVCTL_SECRET_SH:-} ]] && return 0
__DEVCTL_SECRET_SH=1

DEVCTL_SECRETS_DIR="$DEVCTL_DATA_DIR/secrets"

# secret_generate [LENGTH] — random letters and digits (default 32): safe inside SQL, URLs,
# .env files and shell words without any quoting.
secret_generate() {
  local length=${1:-32} out=""
  is_uint "$length" && ((length >= 16 && length <= 128)) || die "$EX_FAIL" "bad secret length (bug)"
  while ((${#out} < length)); do
    out+=$(head -c 96 /dev/urandom | tr -dc 'A-Za-z0-9')
  done
  printf '%s\n' "${out:0:length}"
}

# secret_write FILE KEY=VALUE... — create or replace FILE (0600) atomically.
secret_write() {
  local file=$1 tmp pair
  shift
  ensure_private_dir "${file%/*}"
  tmp=$(mktemp "${file%/*}/.secret.XXXXXX")
  for pair; do
    [[ $pair =~ ^[A-Z][A-Z0-9_]*=[A-Za-z0-9._@:/+-]*$ ]] || { rm -f -- "$tmp"; die "$EX_FAIL" "bad secret entry (bug)"; }
    printf '%s\n' "$pair" >>"$tmp"
  done
  chmod 600 -- "$tmp"
  mv -f -- "$tmp" "$file"
}

# secret_get FILE KEY — print one value.
secret_get() {
  local line
  [[ -r $1 ]] || die "$EX_NOTFOUND" "credentials file missing: $1"
  while IFS= read -r line; do
    if [[ $line == "$2="* ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"$1"
  die "$EX_NOTFOUND" "no $2 in $1"
}
