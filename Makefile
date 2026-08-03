testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this

# Test targets, briefly (see each target's own comment below for the why):
#   test               -- fresh install, default schema. The baseline check.
#   test-schema        -- test, but with TEST_SCHEMA set to a quoting-requiring
#                          schema name.
#   test-update        -- test, but updated from TEST_UPDATE_FROM (default
#                          0.2.2) to the current version instead of a fresh
#                          install. No schema targeting -- symmetric with
#                          test; test-update-schema below is the combination.
#   test-update-schema -- test-update + test-schema together: the one
#                          scenario nothing else covers.
#   test-long          -- every test-* target EXCEPT test itself (currently:
#                          test-update, test-schema, test-update-schema). As
#                          new test-* targets get added, they just join this
#                          prerequisite list -- no redesign needed.
#   test-all           -- test + test-long: the full local pre-push gate.

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

# Scope boundary (deliberate, not an oversight): CI's extension-update-test and
# pg-upgrade-test jobs do NOT exercise TEST_SCHEMA at all yet -- they drive the
# extension through bin/test_existing's own createdb/CREATE EXTENSION/ALTER
# EXTENSION UPDATE flow, not this Makefile's TEST_LOAD_SOURCE path, so none of
# the test-* targets below reach them either. See
# https://github.com/Postgres-Extensions/cat_tools/issues/65 (still open --
# these are local-dev-convenience targets, not a fix for that issue).
#
# Convenience wrapper: `make test-schema` == `make test TEST_SCHEMA=CatToolsSchema`.
# Must recurse (a fresh $(MAKE)) rather than depend on `test`, so the parse-time
# TEST_SCHEMA default above re-evaluates with CatToolsSchema set -- same
# reasoning as test-update below. CatToolsSchema is hardcoded here rather than
# a variable: there's exactly one quoting-requiring name this repo tests
# against (see TEST_SCHEMA above for what it actually proves), so a variable
# indirection would add nothing.
.PHONY: test-schema
test-schema:
	$(MAKE) test TEST_SCHEMA=CatToolsSchema

# Convenience wrapper: `make test-update` == `make test TEST_LOAD_SOURCE=update`.
# Must recurse (a fresh $(MAKE)) rather than depend on `test`, so the parse-time
# TEST_LOAD_SOURCE conditional above re-evaluates with update set. Deliberately
# NO schema targeting -- symmetric with plain `test` above (each is the
# "default schema" leg of its own load mode); test-update-schema below is the
# update+schema combination.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=update

# Convenience wrapper: TEST_LOAD_SOURCE=update AND TEST_SCHEMA=CatToolsSchema
# together -- the one scenario nothing else here covers (test-update above
# covers the update path with no schema targeting; test-schema above covers
# schema targeting on the fresh path only). Also a partial answer to
# https://github.com/Postgres-Extensions/cat_tools/issues/65, which asks for
# TEST_SCHEMA coverage on the update path -- see the scope-boundary comment
# above for the CI-level gap (extension-update-test/pg-upgrade-test) this does
# NOT close.
.PHONY: test-update-schema
test-update-schema:
	$(MAKE) test TEST_LOAD_SOURCE=update TEST_SCHEMA=CatToolsSchema

# .NOTPARALLEL covers this whole test-* family, not just test-long/test-all
# below (the only two with real prerequisites): each of these targets
# recurses into its own $(MAKE) invocation against the SAME throwaway test
# database, and running two of them concurrently (under a hypothetical
# `make -j`) would corrupt that shared state. That lets test-long/test-all
# list bare prerequisites instead of writing out sequential $(MAKE) calls in
# every recipe body. Safe to declare this broadly: nothing in this repo's
# build ever invokes `-j` (grepped ci.yml, this Makefile, sql.mk, lint.mk, and
# pgxntool's own .mk files/docs -- none do), and empirically, GNU Make 4.3's
# `.NOTPARALLEL: a b` does NOT scope narrowly to just `a`/`b` anyway -- it
# serializes the WHOLE invoked build graph once ANY targets are listed, so
# there's no narrower behavior being given up here even in principle.
.NOTPARALLEL: test test-schema test-update test-update-schema test-long test-all

# The rule is simple inclusion, not a CI-cost judgment call: test-long is
# every test-* target EXCEPT test itself, full stop -- currently test-update,
# test-schema, test-update-schema. As new test-* targets get added, they just
# join this prerequisite list, no redesign needed.
#
# test-long is NOT purely a local-dev target, though -- CI's `test` job calls
# `make test-long` directly, on every supported PostgreSQL major (see that
# job's step in ci.yml). So test-update's inclusion here means CI now also
# re-proves part of what that same job's guard-proved update-scenario check
# (a few lines later in the same step) already proves more thoroughly
# (dependency-guard proof + structural diff against a fresh install) --
# real, acknowledged overlap, not an oversight. It's kept anyway: a single
# `make test` pass costs about a second, so one more of them per matrix leg
# (test-long already ran test-schema/test-update-schema either way) is
# negligible -- a wholly different class of cost from the SEPARATE JOB this
# repo removed two rounds ago folding extension-update-test's PG12+ leg into
# this same `test` job, which cost a full extra runner/container/checkout per
# leg (~55s), not one more invocation inside a job already running.
#
# Bare prerequisites, not sequential $(MAKE) calls in the recipe body --
# simpler to read than repeating the same calls here and in each target's own
# definition, and safe only because of the .NOTPARALLEL declaration above.
.PHONY: test-long
test-long: test-update test-schema test-update-schema

# The full local pre-push gate: test (the one target test-long deliberately
# excludes) plus test-long (everything else). Bare prerequisites, safe under
# the same .NOTPARALLEL declaration as test-long.
.PHONY: test-all
test-all: test test-long

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
