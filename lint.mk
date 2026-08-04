# lint.mk — thin wrapper; the whole local footprint for consuming
# https://github.com/Postgres-Extensions/linter. Everything else lives in
# the .vendor/linter submodule; see its README for available targets/rules.
#
# Self-initializing (via the rule below) so `make lint` works right after a
# plain `git clone`, with no --recurse-submodules needed, and so CI can rely
# on the exact same entry point a developer would use locally.
#
# Guarded on $(wildcard .git): the top-level Makefile's `include lint.mk` is
# unconditional, so Make tries to satisfy this file's own includes before
# running ANY target. `git archive` (what `make dist`/PGXN ship) drops
# submodules and .git entirely, so on a released tarball the rule below would
# run `git submodule update` outside a git repo, fail, and abort the whole
# Makefile parse -- breaking even plain `make`/`make install` for every
# consumer, not just `make lint`. Skipping the include there is fine: PGXN
# consumers don't need the linter. $(wildcard .git) matches both a real
# .git directory (plain clone) and the .git file pointer used inside a git
# worktree, and is empty only when neither exists (a tarball extraction).
ifneq ($(wildcard .git),)
.vendor/linter/lint.mk:
	git submodule update --init -- .vendor/linter

include .vendor/linter/lint.mk
endif
