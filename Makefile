# devctl developer tasks. Requires: ShellCheck, bats (dnf install ShellCheck bats).
SHELL := /bin/bash
# Core files are checked through bin/devctl (shellcheck -x follows its source chain), so
# globals shared between core files are understood. Command files source the core themselves.
BASH_FILES := bin/devctl install.sh libexec/devctl-root share/completions/devctl.bash $(sort $(wildcard lib/cmd/*.sh) $(wildcard lib/adapters/*/*.sh)) tests/helpers/common.bash

.PHONY: check lint test test-dashboard itest

check: lint test test-dashboard

lint:
	shellcheck -x $(BASH_FILES)
	@# Each core file on its own too, only for errors: a file that fails to parse would
	@# otherwise be skipped silently when reached through bin/devctl.
	shellcheck -S error $(sort $(wildcard lib/core/*.sh))

test:
	bats tests/unit

test-dashboard:
	cd dashboard && python3 -I -W error::ResourceWarning -m unittest discover -s tests -t .

# Real Docker, isolated (temporary HOME, devctl-itest-* containers). Downloads images.
itest:
	bats tests/integration
