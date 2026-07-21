testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this

# Committed-once install of the extension + test roles.
#
# test/install/load.sql is the ONE place that installs everything the pgTAP
# suite depends on (the extension and the test roles + grants). pgxntool's
# native test/install feature runs it COMMITTED, before the suite, in its own
# pg_regress session; the state persists into every (rolled-back) test. So the
# per-test files no longer each reinstall -- a real time saver. We enable it in
# BOTH modes (install always happens via test/install), so it must be `yes`
# unconditionally here.
PGXNTOOL_ENABLE_TEST_INSTALL = yes
#
# TEST_LOAD_SOURCE selects how load.sql installs the extension:
#   - fresh (default): CREATE EXTENSION cat_tools (current version).
#   - update: CREATE EXTENSION at TEST_UPDATE_FROM (default 0.2.2, the
#     backward-compat floor) then ALTER EXTENSION UPDATE -- to TEST_UPDATE_TO if
#     set, otherwise to the current version. Running the SAME suite with the SAME
#     expected output against the updated database verifies it behaves
#     identically to a fresh install.
#   - existing: the extension is ALREADY installed in the target database (by a
#     binary pg_upgrade, or an ALTER EXTENSION UPDATE done outside the suite).
#     load.sql does not touch it; it only asserts presence + current version and
#     creates the test roles. Pair with CONTRIB_TESTDB=<db> and
#     EXTRA_REGRESS_OPTS=--use-existing so pg_regress runs against that database
#     instead of dropping and recreating a throwaway one.
#
# The mode (and the update from/to versions) are signalled to load.sql by
# placeholder GUCs. pg_regress does not forward make variables, but the psql
# processes it spawns inherit the environment, so PGOPTIONS reaches load.sql.
#
# The GUCs are exported UNCONDITIONALLY, so load.sql can read them WITHOUT
# missing_ok and fail loudly if they did not propagate. Relying on an absent GUC
# to mean "fresh" is unsafe: a silent break anywhere in the
# make -> PGOPTIONS -> env -> psql chain would quietly run the wrong mode.
#
# TEST_LOAD_SOURCE must be exactly `fresh`, `update` or `existing`; anything else
# is a hard error at parse time (so e.g. `make test TEST_LOAD_SOURCE=typo` fails
# fast rather than defaulting).
#
# The install runs COMMITTED (in test/install, not in deps.sql's per-test
# transaction) so it happens once, before the suite, and persists into every
# rolled-back test. See test/install/load.sql.
TEST_LOAD_SOURCE ?= fresh
ifeq ($(filter $(TEST_LOAD_SOURCE),fresh update existing),)
$(error TEST_LOAD_SOURCE must be 'fresh', 'update' or 'existing', got '$(TEST_LOAD_SOURCE)')
endif

# update-mode version range (read by load.sql only in update mode). Empty
# TEST_UPDATE_TO means "update to the current default_version".
TEST_UPDATE_FROM ?= 0.2.2
TEST_UPDATE_TO ?=

export PGOPTIONS := $(PGOPTIONS) -c cat_tools.test_load_mode=$(TEST_LOAD_SOURCE) -c cat_tools.test_update_from=$(TEST_UPDATE_FROM) -c cat_tools.test_update_to=$(TEST_UPDATE_TO)

# Convenience wrapper: `make test-update` == `make test TEST_LOAD_SOURCE=update`.
# Must recurse (a fresh $(MAKE)) rather than depend on `test`, so the parse-time
# TEST_LOAD_SOURCE conditional above re-evaluates with update set.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=update

# Versioned SQL is generated from .sql.in at build time. That generation and the
# DATA list that installs it live in sql.mk, which also owns
# `include pgxntool/base.mk` (base.mk has no include guard, so it must be
# included exactly once; sql.mk includes it at its top). sql.mk documents the
# GNU Make two-phase (parse vs. recipe) hazards involved (e.g.
# https://github.com/Postgres-Extensions/cat_tools/issues/28) and relies on
# base.mk/control.mk/PGXS vars (EXTENSION_VERSION_FILES, PG_CONFIG, MAJORVER,
# datadir, ...). The PGXNTOOL_ENABLE_TEST_INSTALL / TEST_LOAD_SOURCE vars above
# are set before this include so base.mk (pulled in by sql.mk) sees them.
include sql.mk

# Clean the cruft pg_regress writes into test/install/ (the self-comparing
# result .out and its diff), which is listed in test/install/.gitignore. This is
# the pgxntool test/install feature configured above (not SQL generation), so
# its cleanup stays here rather than in sql.mk.
EXTRA_CLEAN += $(addprefix test/install/,$(shell grep -v '^\#' test/install/.gitignore 2>/dev/null))

.PHONY: old_version
old_version: $(DESTDIR)$(datadir)/extension/cat_tools--0.2.0.sql
$(DESTDIR)$(datadir)/extension/cat_tools--0.2.0.sql:
	pgxn install --unstable 'cat_tools=0.2.0'


.PHONY: clean_old_version
clean_old_version:
	pgxn uninstall --unstable 'cat_tools=0.2.0'
