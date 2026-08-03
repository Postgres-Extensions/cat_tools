testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this

# Test targets, briefly (see each target's own comment below for the why):
#   test        -- fresh install, default schema. The baseline check.
#   test-update -- test, but updated from TEST_UPDATE_FROM (default 0.2.2) to
#                  the current version instead of a fresh install.
#   test-long   -- ONLY the scenarios nothing else covers (see
#                  TEST_LONG_SCENARIOS below): TEST_SCHEMA's quoting-requiring
#                  pipeline on the fresh and update paths. Deliberately
#                  excludes anything test/test-update/CI's other jobs already
#                  check.
#   test-all    -- test + test-long: the full local pre-push gate.

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
# An update must be committed (which is why it lives in test/install, not in
# deps.sql's per-test transaction): the update to the current version runs
# ALTER TYPE ... ADD VALUE, and a newly added enum value cannot be USED in the
# transaction that added it (55P04). See test/install/load.sql.
#
# update mode requires PG12+ when it targets the current version (ALTER TYPE
# ... ADD VALUE cannot run in a transaction at all before PG12); CI restricts it
# accordingly.
TEST_LOAD_SOURCE ?= fresh
ifeq ($(filter $(TEST_LOAD_SOURCE),fresh update existing),)
$(error TEST_LOAD_SOURCE must be 'fresh', 'update' or 'existing', got '$(TEST_LOAD_SOURCE)')
endif

# update-mode version range (read by load.sql only in update mode). Empty
# TEST_UPDATE_TO means "update to the current default_version".
TEST_UPDATE_FROM ?= 0.2.2
TEST_UPDATE_TO ?=

# TEST_SCHEMA is a second, independent GUC switch, same propagation mechanism
# as TEST_LOAD_SOURCE above. THE POINT: prove cat_tools works correctly even
# when the 'cat_tools' schema itself is NEVER part of the active search_path --
# a normal, legitimate deployment choice for a tooling extension (so it never
# shadows anything, and callers must always schema-qualify it). If cat_tools'
# own SQL secretly relied on unqualified name resolution somewhere, it would
# keep working by accident in an ordinary fresh-install run (which never
# touches search_path) and only break in that deployment -- TEST_SCHEMA exists
# to force that scenario here instead. See test/install/load.sql for the
# actual mechanism (a schema created and made the ONLY entry on search_path,
# CREATE EXTENSION cat_tools WITH SCHEMA cat_tools run explicitly against it,
# then an assertion that 'cat_tools' never resolves via search_path anyway):
#   - empty (default): none of that -- CREATE EXTENSION cat_tools runs exactly
#     as a brand-new user would type it, no WITH SCHEMA clause, landing
#     wherever the session's ambient search_path already resolves.
#   - non-empty: load.sql creates that schema (quoting it, so a name that
#     requires quoting -- e.g. mixed case -- works) and SETs search_path to
#     ONLY that schema before installing.
#
# Exported unconditionally, same reasoning as TEST_UPDATE_FROM/TO: an empty
# default is fine, and load.sql reads it without missing_ok.
TEST_SCHEMA ?=

export PGOPTIONS := $(PGOPTIONS) -c cat_tools.test_load_mode=$(TEST_LOAD_SOURCE) -c cat_tools.test_update_from=$(TEST_UPDATE_FROM) -c cat_tools.test_update_to=$(TEST_UPDATE_TO) -c cat_tools.test_schema=$(TEST_SCHEMA)

# Schema variant test-long exercises: one mixed-case name that requires SQL
# identifier quoting -- see TEST_SCHEMA above for what this actually proves.
# (The empty/ambient-search_path default is deliberately NOT in test-long's
# scenario list at all -- see TEST_LONG_SCENARIOS below for why.)
#
# Scope boundary (deliberate, not an oversight): CI's extension-update-test and
# pg-upgrade-test jobs do NOT exercise TEST_SCHEMA at all yet -- they drive the
# extension through bin/test_existing's own createdb/CREATE EXTENSION/ALTER
# EXTENSION UPDATE flow, not this Makefile's TEST_LOAD_SOURCE path, so
# test-long below doesn't reach them either. See
# https://github.com/Postgres-Extensions/cat_tools/issues/65 (still open --
# this is a local-dev-convenience fix, not a fix for that issue).
#
# TEST_LONG_SCENARIOS is an explicit list of "TEST_LOAD_SOURCE:TEST_SCHEMA"
# pairs -- NOT a full cross product of every TEST_LOAD_SOURCE x every
# TEST_SCHEMA. test-long exists to cover ONLY what nothing else already
# covers, so BOTH empty-schema combinations are deliberately absent, each for
# a different reason:
#   - {fresh, <empty>} is exactly the plain fresh-install/default-schema case
#     that `make test`/`installcheck` (and CI's `test` job step, via its own
#     explicit `make verify-results` call -- see ci.yml) already checks.
#     test-long including it too would just be re-running that same case
#     again under a different name.
#   - {update, <empty>} is exactly "0.2.2 updated to the current version,
#     default schema, full suite", already proven -- more thoroughly -- by
#     CI's extension-update-test job (bin/test_existing's update_scenario
#     additionally plants and proves the dependency guard) on the SAME
#     PostgreSQL majors (12-18) that the `test` job (and so test-long) runs on.
# Repeating either here would add CI wall-clock with no added confidence. The
# two scenarios kept are exactly the ones nothing else covers: TEST_SCHEMA's
# quoting-requiring pipeline on the fresh path (fresh:CatToolsSchema) and on
# the update path (update:CatToolsSchema) -- the latter also a partial answer
# to https://github.com/Postgres-Extensions/cat_tools/issues/65, which asks
# for TEST_SCHEMA coverage on the update path.
TEST_LONG_SCENARIOS ?= fresh:CatToolsSchema update:CatToolsSchema

# Loops the full suite once per TEST_LONG_SCENARIOS entry via `verify-results`,
# NOT plain `test`: verify-results is this repo's documented CI-safe gate
# (make test alone doesn't reliably fail on regressions the way verify-results
# does -- see CLAUDE.md), and CI relies on test-long to fail loudly on a
# regression the same way a single
# `make verify-results TEST_LOAD_SOURCE=X TEST_SCHEMA=Y` already does. Must
# recurse (a fresh $(MAKE) per iteration, not a plain shell variable) for the
# same reason test-update recurses: these GUCs only take effect if exported
# into PGOPTIONS before the sub-make's own parse phase. Each scenario is
# "load_source:schema"; %% / # parameter expansion splits on the FIRST colon
# (also correct if a schema were ever empty, e.g. "fresh:" -> schema ""), so a
# schema name containing a colon would break this, but none of ours do.
.PHONY: test-long
test-long:
	@for scenario in $(TEST_LONG_SCENARIOS); do \
		load_source=$${scenario%%:*}; \
		schema=$${scenario#*:}; \
		echo "=== TEST_LOAD_SOURCE=$$load_source TEST_SCHEMA=$$schema ==="; \
		$(MAKE) verify-results TEST_LOAD_SOURCE="$$load_source" TEST_SCHEMA="$$schema" || exit 1; \
	done

# Convenience wrapper: `make test-update` == `make test TEST_LOAD_SOURCE=update`.
# Must recurse (a fresh $(MAKE)) rather than depend on `test`, so the parse-time
# TEST_LOAD_SOURCE conditional above re-evaluates with update set. Kept as a
# standalone target for a quick single-mode run; test-long (below) covers the
# same update axis as part of its full loop, so test-all no longer calls this
# separately.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=update

# Runs test (fresh; gates via test's own regression.diffs check, pgxntool
# 2.3.0+, but not as strict as verify-results's pgtap-aware check -- still
# useful as a quick smoke build) followed by test-long, which covers the
# TEST_LONG_SCENARIOS above THROUGH verify-results, this repo's stricter,
# documented gate. Sequential $(MAKE) calls in the recipe body, NOT bare
# prerequisites -- listing them as prerequisites would let Make run them
# concurrently under -j, and they all share the same throwaway test database
# (same hazard already called out by verify-results's own dependency-ordering
# comment in pgxntool/base.mk).
.PHONY: test-all
test-all:
	$(MAKE) test
	$(MAKE) test-long

# Versioned SQL is generated from .sql.in at build time. That generation, the
# DATA list that installs it, and the relkind drift source all live in sql.mk,
# which also owns `include pgxntool/base.mk` (base.mk has no include guard, so it
# must be included exactly once; sql.mk includes it at its top). This Makefile
# therefore does NOT include base.mk itself -- only sql.mk. sql.mk documents the
# GNU Make two-phase (parse vs. recipe) hazards involved (e.g.
# https://github.com/Postgres-Extensions/cat_tools/issues/28) and relies on
# base.mk/control.mk/PGXS vars (EXTENSION__CURRENT_VERSION__FILES, PG_CONFIG, MAJORVER,
# datadir, ...). The PGXNTOOL_ENABLE_TEST_INSTALL / TEST_LOAD_SOURCE vars above
# are set before this include so base.mk (pulled in by sql.mk) sees them.
include sql.mk

# A second PGOPTIONS export, appending to (not replacing) the one above: PGXNVERSION
# (the distribution version from META.json) is only defined AFTER `include sql.mk`
# pulls in base.mk's meta.mk include, so this line cannot be merged into the
# earlier export without $(PGXNVERSION) evaluating empty there. load.sql's
# existing-mode check reads this GUC (cat_tools.pgxn_version) instead of querying
# pg_available_extensions.default_version, because that view is FILESYSTEM-based
# and returns NULL for an extension registered purely via pg_tle (no control file
# on disk) -- exactly the deployment method the pg_tle CI jobs use. This mirrors
# bin/test_existing's own current_version() helper, which already avoids
# pg_available_extensions for the identical reason (it shells out to
# `make -s print-PGXNVERSION` instead).
export PGOPTIONS := $(PGOPTIONS) -c cat_tools.pgxn_version=$(PGXNVERSION)

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

# Style linter (see https://github.com/Postgres-Extensions/linter, vendored
# at .vendor/linter -- lint.mk is the thin local hand-off, see its comment).
# Scoped to the actively-maintained source rather than the default
# `sql/ test/`: version-specific install/update scripts under sql/ are
# frozen once released (SQL file conventions rule 5 in CLAUDE.md — never
# hand-edited again), so linting them would produce permanent, unfixable
# findings and make `make lint` unusable as a CI gate. Lint the current
# source instead; a version file still under active development can be
# linted directly, e.g.
# `.vendor/linter/sql/bin/sql-lint sql/cat_tools--0.3.0.sql.in`.
LINT_TARGETS = sql/cat_tools.sql.in test/
include lint.mk
