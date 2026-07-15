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
#   - upgrade: CREATE EXTENSION at the 0.2.2 backward-compat floor and
#     ALTER EXTENSION UPDATE to the current version. Running the SAME suite
#     with the SAME expected output against the upgraded database verifies it
#     behaves identically to a fresh install.
#
# The mode is signalled to load.sql by the cat_tools.test_load_mode placeholder
# GUC. pg_regress does not forward make variables, but the psql processes it
# spawns inherit the environment, so PGOPTIONS reaches load.sql.
#
# The GUC is exported UNCONDITIONALLY (with the mode value), so load.sql can read
# it WITHOUT missing_ok and fail loudly if it did not propagate. Relying on an
# absent GUC to mean "fresh" is unsafe: a silent break anywhere in the
# make -> PGOPTIONS -> env -> psql chain would quietly run fresh in place of the
# intended upgrade test. Making the mode explicit and required removes that trap.
#
# TEST_LOAD_SOURCE must be exactly `fresh` or `upgrade`; anything else is a hard
# error at parse time (so e.g. `make test TEST_LOAD_SOURCE=typo` fails fast
# rather than defaulting).
#
# The upgrade must be committed (which is why it lives in test/install, not in
# deps.sql's per-test transaction): the update to the current version runs
# ALTER TYPE ... ADD VALUE, and a newly added enum value cannot be USED in the
# transaction that added it (55P04). See test/install/load.sql.
#
# Upgrade mode requires PG12+ (ALTER TYPE ... ADD VALUE cannot run in a
# transaction at all before PG12); CI restricts it accordingly.
TEST_LOAD_SOURCE ?= fresh
ifeq ($(filter $(TEST_LOAD_SOURCE),fresh upgrade),)
$(error TEST_LOAD_SOURCE must be 'fresh' or 'upgrade', got '$(TEST_LOAD_SOURCE)')
endif
export PGOPTIONS := $(PGOPTIONS) -c cat_tools.test_load_mode=$(TEST_LOAD_SOURCE)

# Convenience wrapper: `make test-update` == `make test TEST_LOAD_SOURCE=upgrade`.
# Must recurse (a fresh $(MAKE)) rather than depend on `test`, so the parse-time
# TEST_LOAD_SOURCE conditional above re-evaluates with upgrade set.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=upgrade

include pgxntool/base.mk

# Versioned SQL is generated from .sql.in at build time. That generation, the
# DATA list that installs it, and the relkind drift source all live in sql.mk,
# which documents the GNU Make two-phase (parse vs. recipe) hazards involved
# (e.g. #28). Include it AFTER base.mk so it can use base.mk/control.mk/PGXS
# vars (EXTENSION_VERSION_FILES, PG_CONFIG, MAJORVER, datadir, ...).
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
