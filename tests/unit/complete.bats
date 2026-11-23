#!/usr/bin/env bats
load '../helpers/common'

setup() { setup_home; }

complete_words() { devctl complete -- "$@" | paste -sd' '; }

@test "commands, without hidden ones" {
  run complete_words ""
  [[ $output == *config* && $output == *dashboard* && $output == *self* ]]
  [[ $output != *complete* ]]
}

@test "prefix filtering and subcommands" {
  [ "$(complete_words co)" = config ]
  [ "$(complete_words config '')" = "get path show" ]
  [ "$(complete_words dashboard s)" = "start status stop" ]
}

@test "setting names for config get" {
  [ "$(complete_words config get dom)" = "domain.reserved domain.suffix" ]
}

@test "global flags anywhere, command flags, --color values" {
  [ "$(complete_words --col)" = "--color=" ]
  [ "$(complete_words --color=a)" = "--color=auto --color=always" ]
  [[ "$(complete_words history --)" == *"--limit --actions --alerts"* ]]
  [[ "$(complete_words self install --f)" == "--force" ]]
  [ "$(complete_words -q config get ui.)" = ui.color ]
}

@test "help completes command names; unknown command completes nothing" {
  [ "$(complete_words help hi)" = history ]
  [ -z "$(complete_words nope '')" ]
}

@test "bash completion function (fallback without bash-completion)" {
  run bash -c "
    PATH='$REPO_ROOT/bin':\$PATH
    source '$REPO_ROOT/share/completions/devctl.bash'
    COMP_WORDS=(devctl dash); COMP_CWORD=1; _devctl; echo \"\${COMPREPLY[*]}\"
    COMP_WORDS=(devctl --color=al); COMP_CWORD=1; _devctl; echo \"\${COMPREPLY[*]}\""
  [ "${lines[0]}" = dashboard ]
  [ "${lines[1]}" = always ]
}
