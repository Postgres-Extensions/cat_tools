# lint.mk — thin wrapper; the whole local footprint for consuming
# https://github.com/Postgres-Extensions/linter. Everything else lives in
# the .vendor/linter submodule; see its README for available targets/rules.
#
# Self-initializing (via the rule below) so `make lint` works right after a
# plain `git clone`, with no --recurse-submodules needed, and so CI can rely
# on the exact same entry point a developer would use locally.
.vendor/linter/lint.mk:
	git submodule update --init -- .vendor/linter

include .vendor/linter/lint.mk
