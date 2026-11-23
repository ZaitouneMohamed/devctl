# shellcheck shell=bash
# summary: GitHub: sign in with gh, list your repositories, clone them as sites

# Command files run inside devctl's core. This line is a no-op at runtime (the core is
# already loaded and guarded against double loading); it tells shellcheck where the
# shared globals and functions come from.
# shellcheck source=lib/core/bootstrap.sh
source "${DEVCTL_ROOT:?}/lib/core/bootstrap.sh"

register_action github.setup github.install github.login github.logout github.identity

gh_installed() { command -v gh >/dev/null; }
gh_logged_in() { gh_installed && gh auth status --hostname github.com >/dev/null 2>&1; }
gh_user() { gh api user --jq .login 2>/dev/null; }

cmd_github() { cmd_github_status "$@"; }

cmd_github_status() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl github status"
  local installed=no logged=no user="" name email
  gh_installed && installed=yes
  gh_logged_in && logged=yes && user=$(gh_user)
  name=$(git config --global user.name || true)
  email=$(git config --global user.email || true)
  if ((DEVCTL_JSON)); then
    jq -nc --arg i "$installed" --arg l "$logged" --arg u "$user" --arg n "$name" --arg e "$email" \
      '{gh_installed: ($i == "yes"), logged_in: ($l == "yes"), user: $u, git_name: $n, git_email: $e}'
    return 0
  fi
  {
    printf 'gh (GitHub CLI)\t%s\n' "$installed"
    printf 'signed in\t%s\n' "$([[ $logged == yes ]] && echo "yes, as $user" || echo no)"
    printf 'git name\t%s\n' "${name:-not set}"
    printf 'git email\t%s\n' "${email:-not set}"
  } | ui_table
  [[ $logged == yes ]] || ui_note "set up with: devctl github setup"
  [[ -n $name && -n $email ]] || ui_note "set your git identity: git config --global user.name \"…\"; git config --global user.email \"…\""
}

# setup: install gh (Fedora package) and sign in through the browser (your terminal).
cmd_github_setup() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl github setup"
  if ! gh_installed; then
    confirm_or_abort "Install the GitHub CLI (Fedora package gh)?" yes
    priv_run --desc "Install gh" pkg-install gh || die "$EX_EXTERNAL" "could not install gh"
  fi
  ((DEVCTL_DRY_RUN)) && { ui_plan "gh auth login --hostname github.com --git-protocol https --web"; return 0; }
  if gh_logged_in; then
    ui_skip "already signed in to GitHub as $(gh_user)"
  else
    [[ -t 0 ]] || die "$EX_PRECONDITION" "signing in needs your terminal: run devctl github setup there"
    ui_step "Signing in to GitHub: gh shows a one-time code and opens your browser"
    gh auth login --hostname github.com --git-protocol https --web || die "$EX_EXTERNAL" "GitHub sign-in did not finish"
  fi
  # Lets plain `git clone/pull/push` over HTTPS use gh's sign-in (private repositories).
  run_change --desc "Use gh's sign-in for git over HTTPS" -- gh auth setup-git --hostname github.com ||
    die "$EX_EXTERNAL" "gh auth setup-git failed"
  ui_ok "GitHub is ready as $(gh_user). Your repositories: devctl github repos"
}

# install: just the gh package (the dashboard's Setup page uses this, then login).
cmd_github_install() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl github install"
  if gh_installed; then ui_skip "gh is already installed"; return 0; fi
  priv_run --desc "Install gh" pkg-install gh || die "$EX_EXTERNAL" "could not install gh"
  ((DEVCTL_DRY_RUN)) || ui_ok "gh installed"
}

# login [--with-token]: browser sign-in (device code) or a personal access token on stdin.
# Works without a terminal, so the dashboard can show the code and the link.
cmd_github_login() {
  local with_token=0
  case ${1:-} in
    "") ;;
    --with-token) with_token=1 ;;
    *) die "$EX_USAGE" "usage: devctl github login [--with-token < token]" ;;
  esac
  gh_installed || die "$EX_PRECONDITION" "gh is not installed: devctl github install"
  if gh_logged_in; then ui_skip "already signed in to GitHub as $(gh_user)"; return 0; fi
  ((DEVCTL_DRY_RUN)) && { ui_plan "gh auth login --hostname github.com --git-protocol https"; return 0; }
  if ((with_token)); then
    local token
    IFS= read -r token || true
    # Classic (ghp_) or fine-grained (github_pat_) tokens; never printed, never on a command line.
    [[ $token =~ ^(ghp_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{40,255})$ ]] ||
      die "$EX_VALIDATION" "that does not look like a GitHub personal access token (ghp_… or github_pat_…)"
    printf '%s\n' "$token" | gh auth login --hostname github.com --git-protocol https --with-token ||
      die "$EX_EXTERNAL" "GitHub rejected the token"
  else
    ui_step "GitHub sign-in: open https://github.com/login/device and enter the one-time code below"
    GH_PROMPT_DISABLED=1 gh auth login --hostname github.com --git-protocol https --web </dev/null ||
      die "$EX_EXTERNAL" "GitHub sign-in did not finish"
  fi
  run_change --desc "Use gh's sign-in for git over HTTPS" -- gh auth setup-git --hostname github.com ||
    die "$EX_EXTERNAL" "gh auth setup-git failed"
  ui_ok "Signed in to GitHub as $(gh_user)"
}

cmd_github_logout() {
  (($# == 0)) || die "$EX_USAGE" "usage: devctl github logout"
  gh_logged_in || { ui_skip "not signed in"; return 0; }
  confirm_or_abort "Sign out of GitHub as $(gh_user)? (private repositories stop working until you sign in again)"
  run_change --desc "Sign out" -- gh auth logout --hostname github.com || die "$EX_EXTERNAL" "sign-out failed"
  ((DEVCTL_DRY_RUN)) || ui_ok "Signed out of GitHub"
}

# identity --name N --email E: your git name and email (git config --global), as you typed them.
cmd_github_identity() {
  local name="" email=""
  while (($#)); do
    case $1 in
      --name) name=${2:-}; shift 2 ;;
      --name=*) name=${1#*=}; shift ;;
      --email) email=${2:-}; shift 2 ;;
      --email=*) email=${1#*=}; shift ;;
      *) die "$EX_USAGE" "usage: devctl github identity --name \"Your Name\" --email you@example.com" ;;
    esac
  done
  [[ -n $name && ${#name} -le 100 && $name != *[[:cntrl:]]* && $name =~ [[:alpha:]] ]] ||
    die "$EX_VALIDATION" "name: 1-100 characters, letters required"
  [[ ${#email} -le 254 && $email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
    die "$EX_VALIDATION" "that is not a valid email address"
  run_change --desc "Set git name" -- git config --global user.name "$name" || die "$EX_EXTERNAL" "git config failed"
  run_change --desc "Set git email" -- git config --global user.email "$email" || die "$EX_EXTERNAL" "git config failed"
  ((DEVCTL_DRY_RUN)) || ui_ok "git will sign your commits as $name <$email>"
}

# repos: every repository you can push to or read as owner, collaborator or organisation
# member, newest push first. One GraphQL query (paginated), cached for GITHUB_CACHE_SECONDS
# in ~/.cache/devctl (0600) so lists open instantly; --refresh asks GitHub again.
readonly GITHUB_CACHE_SECONDS=900
GITHUB_CACHE_FILE="$DEVCTL_CACHE_DIR/github-repos.json"

github__fetch_repos() {
  # shellcheck disable=SC2016  # $endCursor is a GraphQL variable, not a shell one
  gh api graphql --paginate --slurp -f query='
    query($endCursor: String) {
      viewer {
        repositories(first: 100, after: $endCursor,
                     affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                     orderBy: {field: PUSHED_AT, direction: DESC}) {
          nodes { nameWithOwner description isPrivate pushedAt url primaryLanguage { name } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' | jq -c '[.[].data.viewer.repositories.nodes[]] | unique_by(.nameWithOwner) | sort_by(.pushedAt) | reverse
      | map({repo: .nameWithOwner, description: (.description // ""), language: (.primaryLanguage.name // ""),
             private: .isPrivate, pushed: .pushedAt, url})'
}

github__cache_age() { # seconds since the cache was written, or a huge number
  [[ -f $GITHUB_CACHE_FILE ]] || { echo 999999999; return; }
  echo $(($(printf '%(%s)T' -1) - $(stat -c %Y -- "$GITHUB_CACHE_FILE")))
}

cmd_github_repos() {
  local owner="" limit=1000 refresh=0 cached_only=0
  while (($#)); do
    case $1 in
      --owner) owner=${2:-}; shift 2 ;;
      --owner=*) owner=${1#*=}; shift ;;
      --limit) limit=${2:-}; shift 2 ;;
      --refresh) refresh=1; shift ;;
      --cached) cached_only=1; shift ;;
      *) die "$EX_USAGE" "usage: devctl github repos [--owner USER_OR_ORG] [--limit N] [--refresh|--cached]" ;;
    esac
  done
  require_valid uint "$limit" "--limit"
  [[ -z $owner || $owner =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || die "$EX_VALIDATION" "invalid owner '$owner'"

  local json age
  age=$(github__cache_age)
  if ((cached_only)); then
    [[ -f $GITHUB_CACHE_FILE ]] || die "$EX_NOTFOUND" "no cached repository list yet"
  elif ((refresh || age >= GITHUB_CACHE_SECONDS)); then
    gh_logged_in || die "$EX_PRECONDITION" "not signed in to GitHub: devctl github setup"
    json=$(github__fetch_repos) || die "$EX_EXTERNAL" "could not list your repositories (network?)"
    ensure_private_dir "$DEVCTL_CACHE_DIR"
    (umask 077 && printf '%s\n' "$json" >"$GITHUB_CACHE_FILE.tmp") && mv -f -- "$GITHUB_CACHE_FILE.tmp" "$GITHUB_CACHE_FILE"
    age=0
  fi
  json=$(jq -c --arg o "$owner" --argjson n "$limit" \
    '[.[] | select($o == "" or (.repo | ascii_downcase | startswith(($o | ascii_downcase) + "/")))][:$n]' "$GITHUB_CACHE_FILE")

  if ((DEVCTL_JSON)); then
    printf '%s\n' "$json"
    return 0
  fi
  {
    printf 'REPOSITORY\tLANGUAGE\tVISIBILITY\tLAST PUSH\n'
    jq -r '.[] | [.repo, (if .language == "" then "-" else .language end), (if .private then "private" else "public" end), .pushed[:10]] | @tsv' <<<"$json"
  } | ui_table
  ((age >= 60)) && ui_note "list from $((age / 60)) min ago (devctl github repos --refresh for a new one)"
  ui_note "clone one as a site: devctl site clone OWNER/REPO --category elden"
}

complete_github() {
  [[ $1 == flags && $2 == repos ]] && printf '%s\n' --owner --limit --refresh --cached
  return 0
}

help_github() {
  cat <<'HELP'
Usage: devctl github [status]        gh installed? signed in? git name/email set?
       devctl github setup           install gh, sign in through the browser (terminal)
       devctl github install         install gh only
       devctl github login [--with-token]   browser sign-in (one-time code) or a token on stdin
       devctl github logout
       devctl github identity --name "Your Name" --email you@example.com   git config --global
       devctl github repos [--owner X] [--limit N] [--refresh]   repositories you own, collaborate on,
                                     or reach through an organisation (cached 15 min)

Then: devctl site clone OWNER/REPO [--name NAME] [--category elden|personal|school]
Private repositories clone with your gh sign-in (gh auth setup-git).
HELP
}
