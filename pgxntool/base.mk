# Include guard: base.mk can end up included twice in a single `make` run
# (e.g. an extension's own .mk module includes it, and the extension's
# Makefile also includes it directly via the line setup.sh writes). Without
# this, every target in the file gets redefined, producing
# overriding-recipe/ignoring-old-recipe warnings. A second inclusion is a
# harmless no-op.
ifndef PGXNTOOL_BASE_MK_INCLUDED
PGXNTOOL_BASE_MK_INCLUDED := 1

PGXNTOOL_DIR := pgxntool

# Ensure 'all' is the default target (not META.json which happens to be first)
.DEFAULT_GOAL := all

#
# META.json
#
PGXNTOOL_distclean += META.json
META.json: META.in.json $(PGXNTOOL_DIR)/build_meta.sh
	@$(PGXNTOOL_DIR)/build_meta.sh $< $@

#
# meta.mk
#
# Build meta.mk, which contains PGXN distribution info from META.json
PGXNTOOL_distclean += meta.mk
meta.mk: META.json Makefile $(PGXNTOOL_DIR)/base.mk $(PGXNTOOL_DIR)/meta.mk.sh
	@$(PGXNTOOL_DIR)/meta.mk.sh $< >$@

-include meta.mk

#
# control.mk
#
# Build control.mk, which contains extension info from .control files
# This is separate from meta.mk because:
#   - META.json specifies PGXN distribution metadata
#   - .control files specify what PostgreSQL actually uses (e.g., default_version)
# These can differ, and PostgreSQL cares about the control file version.
#
# Find all control files first (needed for dependencies)
PGXNTOOL_CONTROL_FILES := $(wildcard *.control)
PGXNTOOL_distclean += control.mk
control.mk: $(PGXNTOOL_CONTROL_FILES) Makefile $(PGXNTOOL_DIR)/base.mk $(PGXNTOOL_DIR)/control.mk.sh
	@$(PGXNTOOL_DIR)/control.mk.sh $(PGXNTOOL_CONTROL_FILES) >$@

-include control.mk

# $(wildcard sql/*--*.sql) covers both upgrade scripts (ext--a--b.sql) and
# historical full-install scripts (ext--a.sql); EXTENSION__CURRENT_VERSION__FILES
# is also matched by it but is listed explicitly since it's a generated file
# that must exist as a prerequisite before the wildcard can see it. $(sort)
# dedupes the resulting overlap -- without it, `install` is invoked with the
# current-version file listed twice and refuses to overwrite the copy it
# just created, failing `make install` outright.
DATA         = $(sort $(EXTENSION__CURRENT_VERSION__FILES) $(wildcard sql/*--*.sql))
DOC_DIRS	+= doc
# NOTE: if this is empty it gets forcibly defined to NUL before including PGXS
DOCS		+= $(foreach dir,$(DOC_DIRS),$(wildcard $(dir)/*))

# Find all asciidoc targets
ASCIIDOC ?= $(shell which asciidoctor 2>/dev/null || which asciidoc 2>/dev/null)
ASCIIDOC_EXTS	+= adoc asciidoc asc
ASCIIDOC_FILES	+= $(foreach dir,$(DOC_DIRS),$(foreach ext,$(ASCIIDOC_EXTS),$(wildcard $(dir)/*.$(ext))))

PG_CONFIG   ?= pg_config
TESTDIR		?= test
TESTOUT		?= $(TESTDIR)
TEST_SQL_FILES		+= $(wildcard $(TESTDIR)/sql/*.sql)
TEST_RESULT_FILES	 = $(patsubst $(TESTDIR)/sql/%.sql,$(TESTDIR)/expected/%.out,$(TEST_SQL_FILES))
TEST_FILES	 = $(TEST_SQL_FILES)
REGRESS		 = $(sort $(notdir $(TEST_FILES:.sql=)))
REGRESS_OPTS = --inputdir=$(TESTDIR) --outputdir=$(TESTOUT) # See additional setup below

#
# OPTIONAL TEST FEATURES
#
# These sections configure optional test features. Each feature can be enabled/disabled
# via a makefile variable. If not explicitly set, features auto-detect based on
# directory existence or default behavior. The actual feature implementation is
# located later in this file (see test-build target, schedule file generation, etc.).
#

# Helper function: normalize a yes/no variable to lowercase and validate.
# Usage: $(call pgxntool_validate_yesno,VALUE,VARIABLE_NAME)
# Returns the lowercase value ("yes" or "no"), or errors if invalid.
pgxntool_validate_yesno = $(strip \
  $(if $(filter yes no,$(shell echo "$(1)" | tr '[:upper:]' '[:lower:]')),\
    $(shell echo "$(1)" | tr '[:upper:]' '[:lower:]'),\
    $(error $(2) must be "yes" or "no", got "$(1)")))

# ------------------------------------------------------------------------------
# test-build: Sanity check extension files before running full test suite
# ------------------------------------------------------------------------------
# Purpose: Validates that extension SQL files are syntactically correct by running
#          files from test/build/ through pg_regress. This provides better error
#          messages than CREATE EXTENSION failures.
#
# Variable: PGXNTOOL_ENABLE_TEST_BUILD
#   - Can be set manually in Makefile or command line
#   - Allowed values: "yes" or "no" (case-insensitive)
#   - If not set: Auto-detects based on existence of test/build/*.sql files
#   - Set to "yes" explicitly to get an error if test/build/ has no SQL files
#     (useful to catch accidental deletion of test/build/ contents)
#   - Set to "no" explicitly to disable even when test/build/ has SQL files
#
# Implementation: See test-build target definition (search for "test-build:" in this file)
#
TEST_BUILD_SQL_FILES = $(wildcard $(TESTDIR)/build/*.sql)
TEST_BUILD_FILES = $(TEST_BUILD_SQL_FILES)
ifdef PGXNTOOL_ENABLE_TEST_BUILD
  # override needed so command-line values (make VAR=YES) are normalized, not silently ignored.
  # := needed for immediate evaluation of the function call (avoids infinite recursion with =).
  override PGXNTOOL_ENABLE_TEST_BUILD := $(call pgxntool_validate_yesno,$(PGXNTOOL_ENABLE_TEST_BUILD),PGXNTOOL_ENABLE_TEST_BUILD)
else
  # Auto-detect: enable if test/build/ directory has SQL files
  ifneq ($(strip $(TEST_BUILD_FILES)),)
    PGXNTOOL_ENABLE_TEST_BUILD = yes
  else
    PGXNTOOL_ENABLE_TEST_BUILD = no
  endif
endif

# ------------------------------------------------------------------------------
# test/install: Run setup files before all tests in the same pg_regress session
# ------------------------------------------------------------------------------
# Purpose: Runs files from test/install/ before all test/sql/ files within a
#          SINGLE pg_regress invocation via schedule files. This ensures that
#          state created by install files (tables, extensions, etc.) persists
#          into the main test suite.
#
# Variable: PGXNTOOL_ENABLE_TEST_INSTALL
#   - Can be set manually in Makefile or command line
#   - Allowed values: "yes" or "no" (case-insensitive)
#   - If not set: Auto-detects based on existence of test/install/*.sql files
#   - Set to "yes" explicitly to get an error if test/install/ has no SQL files
#     (useful to catch accidental deletion of test/install/ contents)
#   - Set to "no" explicitly to disable even when test/install/ has SQL files
#
# Directory layout (follows ~/code/extensions/archive/ pattern):
#   test/install/*.sql      - Install SQL files
#   test/install/*.out      - Expected output (lives alongside .sql files)
#   test/install/schedule   - Auto-generated schedule file
#   test/sql/schedule       - Auto-generated schedule file for regular tests
#
# The schedule files use relative paths (../install/testname) so pg_regress
# resolves install files from their original location without copying.
#
# NOTE: The variable normalization pattern below (ifdef/NORM/error/override) is
# identical to test-build and verify-results. Refactoring options:
#   1. A $(call normalize_bool_var,VAR,DEFAULT) Make function
#   2. A small include fragment (e.g. pgxntool/mk/bool-var.mk)
# Either approach would eliminate the ~10-line block repeated for each feature.
TEST_INSTALL_SQL_FILES = $(wildcard $(TESTDIR)/install/*.sql)
ifdef PGXNTOOL_ENABLE_TEST_INSTALL
  # override needed so command-line values (make VAR=YES) are normalized, not silently ignored.
  # := needed for immediate evaluation of the function call (avoids infinite recursion with =).
  override PGXNTOOL_ENABLE_TEST_INSTALL := $(call pgxntool_validate_yesno,$(PGXNTOOL_ENABLE_TEST_INSTALL),PGXNTOOL_ENABLE_TEST_INSTALL)
else
  # Auto-detect: enable if test/install/ directory has SQL files
  ifneq ($(strip $(TEST_INSTALL_SQL_FILES)),)
    PGXNTOOL_ENABLE_TEST_INSTALL = yes
  else
    PGXNTOOL_ENABLE_TEST_INSTALL = no
  endif
endif

# ------------------------------------------------------------------------------
# verify-results: Safeguard for make results
# ------------------------------------------------------------------------------
# Purpose: Prevents accidentally running 'make results' when tests are failing.
#
# Variable: PGXNTOOL_ENABLE_VERIFY_RESULTS
#   - Can be set manually in Makefile or command line
#   - Allowed values: "yes" or "no" (case-insensitive)
#   - Setting to empty on the command line (e.g. PGXNTOOL_ENABLE_VERIFY_RESULTS=) also disables the feature
#   - If not set: Defaults to "yes" (enabled by default for all pgxntool projects)
#   - Usage: Controls whether verify-results target exists and blocks make results
#
# Variable: PGXNTOOL_VERIFY_RESULTS_MODE
#   - Controls how verify-results detects test failures
#   - "pgtap" (default): scans test/results/*.out for "not ok" lines and plan
#     mismatches (TAP failures). Also checks regression.diffs as a fallback.
#     Use this mode when your test suite uses pgTap.
#   - "diffs": checks only for regression.diffs existence (classic pg_regress behavior)
#     Use this mode when your tests use plain SQL expected-output comparison only.
#
# Implementation: See verify-results target definition and results target modification
#                 (search for "verify-results" and "results:" in this file)
#
ifdef PGXNTOOL_ENABLE_VERIFY_RESULTS
  override PGXNTOOL_ENABLE_VERIFY_RESULTS := $(call pgxntool_validate_yesno,$(PGXNTOOL_ENABLE_VERIFY_RESULTS),PGXNTOOL_ENABLE_VERIFY_RESULTS)
else
  # Default to yes (enabled by default for all pgxntool projects)
  PGXNTOOL_ENABLE_VERIFY_RESULTS = yes
endif

# Default mode: pgtap (scans results/*.out for TAP failures)
PGXNTOOL_VERIFY_RESULTS_MODE ?= pgtap

# ------------------------------------------------------------------------------
# check-stale-expected: catch orphaned/unexpected test/expected/ files
# ------------------------------------------------------------------------------
# Variable: PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED
#   - Can be set manually in Makefile or command line
#   - Allowed values: "yes" or "no" (case-insensitive)
#   - Default: "yes" (enabled by default for all pgxntool projects)
#   - Set to "no" to make this check a complete no-op: the target is
#     dropped from TEST_DEPS entirely (see its own definition below)
#
# Variable: PGXNTOOL_CHECK_EXPECTED_FILE_TYPES
#   - Sub-check, independent of the variable above: fails if test/expected/
#     (or test/build/expected/) contains any file that isn't *.out
#   - Allowed values: "yes" or "no" (case-insensitive)
#   - Default: "yes"
#   - Set to "no" to disable just this sub-check while leaving the rest of
#     check-stale-expected (the orphaned-.out check) active
#   - Passed through to check-stale-expected.sh; see that script for the
#     distinct error message/exit code this sub-check uses
#
# Variable: _CHECK_STALE_EXPECTED_SCRIPT (internal shim, not user-facing)
#   - Path to the script the check-stale-expected target invokes
#   - Default: $(PGXNTOOL_DIR)/test/bin/check-stale-expected.sh
#
# Implementation: See check-stale-expected target definition (search for
# "check-stale-expected:" in this file)
#
ifdef PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED
  override PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED := $(call pgxntool_validate_yesno,$(PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED),PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED)
else
  PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED = yes
endif

ifdef PGXNTOOL_CHECK_EXPECTED_FILE_TYPES
  override PGXNTOOL_CHECK_EXPECTED_FILE_TYPES := $(call pgxntool_validate_yesno,$(PGXNTOOL_CHECK_EXPECTED_FILE_TYPES),PGXNTOOL_CHECK_EXPECTED_FILE_TYPES)
else
  PGXNTOOL_CHECK_EXPECTED_FILE_TYPES = yes
endif

_CHECK_STALE_EXPECTED_SCRIPT ?= $(PGXNTOOL_DIR)/test/bin/check-stale-expected.sh

# Generate unique database name for tests to prevent conflicts across projects
# Uses project name + first 5 chars of md5 hash of current directory
# This prevents multiple test runs in different directories from clobbering each other
REGRESS_DBHASH := $(shell echo $(CURDIR) | (md5 2>/dev/null || md5sum) | cut -c1-5)
REGRESS_DBNAME := $(or $(PGXN),regression)_$(REGRESS_DBHASH)
MODULES      = $(patsubst %.c,%,$(wildcard src/*.c))
ifeq ($(strip $(MODULES)),)
MODULES =# Set to NUL so PGXS doesn't puke
endif

EXTRA_CLEAN  = $(wildcard ../$(PGXN)-*.zip) pg_tle/
# PGXS's own pg_regress_clean_files unconditionally rm -rf's a top-level
# results/, but our tests write to $(TESTOUT)/results/ (see REGRESS_OPTS
# --outputdir above), so that's the directory that actually needs cleaning.
# filter-out (not -=, which GNU Make 4.4+ rejects as a parse error) guards
# against a stray top-level results/ entry while adding the real one.
EXTRA_CLEAN := $(filter-out results/,$(EXTRA_CLEAN)) $(TESTOUT)/results/

# Get Postgres version, as well as major (9.4, etc) version.
# NOTE! In at least some versions, PGXS defines VERSION, so we intentionally don't use that variable
PGVERSION 	 = $(shell $(PG_CONFIG) --version | awk '{sub("(alpha|beta|devel).*", ""); print $$2}')
# Multiply by 10 is easiest way to handle version 10+
MAJORVER 	 = $(shell echo $(PGVERSION) | awk -F'.' '{if ($$1 >= 10) print $$1 * 10; else print $$1 * 10 + $$2}')

# Function for testing a condition
test		 = $(shell test $(1) $(2) $(3) && echo yes || echo no)

GE91		 = $(call test, $(MAJORVER), -ge, 91)

ifeq ($(GE91),yes)
all: $(EXTENSION__CURRENT_VERSION__FILES)
endif

ifeq ($(call test, $(MAJORVER), -lt, 130), yes)
REGRESS_OPTS += --load-language=plpgsql
endif

#
# test/install: Schedule-based approach
#
# When enabled, generates a schedule file listing install files, and adds it
# to REGRESS_OPTS. pg_regress processes --schedule tests before command-line
# test names, so install files run first in the SAME pg_regress invocation.
# This ensures state created by install files persists into the main test suite.
#
# The schedule uses relative paths (../install/testname) so pg_regress finds
# install files in their original location without copying.
#
ifeq ($(PGXNTOOL_ENABLE_TEST_INSTALL),yes)
PGXNTOOL_INSTALL_SCHEDULE = $(TESTDIR)/install/schedule
EXTRA_CLEAN += $(PGXNTOOL_INSTALL_SCHEDULE)

# Add install schedule; REGRESS stays as-is (regular tests run after schedule)
REGRESS_OPTS += --schedule=$(PGXNTOOL_INSTALL_SCHEDULE)

# Always regenerate schedule file to catch added/removed files
.PHONY: $(PGXNTOOL_INSTALL_SCHEDULE)
$(PGXNTOOL_INSTALL_SCHEDULE):
	@echo "# Auto-generated - DO NOT EDIT" > $@
	@for f in $(notdir $(basename $(TEST_INSTALL_SQL_FILES))); do \
		echo "test: ../install/$$f" >> $@; \
	done

installcheck: $(PGXNTOOL_INSTALL_SCHEDULE)
endif

PGXS := $(shell $(PG_CONFIG) --pgxs)
# Need to do this because we're not setting EXTENSION
MODULEDIR = extension
DATA += $(wildcard *.control)

# Don't have installcheck bomb on error
.IGNORE: installcheck
installcheck: $(TEST_RESULT_FILES) $(TEST_SQL_FILES) | $(TESTDIR)/sql/ $(TESTDIR)/expected/ $(TESTOUT)/results/

# installcheck must run after install: pg_regress needs the extension already
# installed (CREATE EXTENSION requires the control/SQL files to be in place).
# PGXS's own installcheck target doesn't declare that dependency -- it assumes
# the caller runs `make install installcheck` manually. That assumption breaks
# when something else (e.g. check-stale-expected below) depends on installcheck
# directly: `test`'s TEST_DEPS lists install/installcheck as independent,
# unordered prerequisites, so nothing stops installcheck's own prerequisite
# chain from running before install. An explicit edge here, same as
# check-stale-expected's, is the only ordering guarantee Make actually gives.
installcheck: install

#
# TEST SUPPORT
#
# These targets are meant to make running tests easier.

# Build test dependencies list based on enabled features. This base
# assignment (a plain `=`, not `+=`) must come before any `TEST_DEPS +=`
# line below -- Make processes the file top-to-bottom, and a later plain
# `=` would silently wipe out any `+=` that came before it.
TEST_DEPS = testdeps

# ------------------------------------------------------------------------------
# check-stale-expected: catch orphaned/unexpected test/expected/ files
# ------------------------------------------------------------------------------
# Purpose: test/expected/*.out must mirror test/sql/*.sql 1:1 (likewise
# test/build/expected/*.out vs test/build/*.sql, when test-build is in use).
# It's easy to leave a stale .out behind after renaming or removing a .sql
# file; this makes `make test` fail loudly instead of letting it linger
# unnoticed. Logic lives in check-stale-expected.sh (enough of it to warrant
# a real script rather than an inline recipe).
#
# This depends on `installcheck` directly (not just position in TEST_DEPS)
# because it MUST run after pg_regress, not before: TEST_DEPS lists multiple
# independent prerequisites of `test`, and Make does not guarantee the order
# unrelated prerequisites of the same target are built in. An explicit
# dependency edge is the only ordering guarantee Make actually gives.
#
# See PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED / PGXNTOOL_CHECK_EXPECTED_FILE_TYPES
# above for how to disable this entirely or just its non-.out file sub-check.
ifeq ($(PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED),yes)
.PHONY: check-stale-expected
check-stale-expected: installcheck
	@$(_CHECK_STALE_EXPECTED_SCRIPT) $(TESTDIR) $(PGXNTOOL_CHECK_EXPECTED_FILE_TYPES)
TEST_DEPS += check-stale-expected
endif

# make test: run any test dependencies, then do a `make install installcheck`.
# If regressions are found, it will output them.
#
# This used to depend on clean as well, but that causes problems with
# watch-make if you're generating intermediate files. If tests end up needing
# clean it's an indication of a missing dependency anyway.
.PHONY: test
ifeq ($(PGXNTOOL_ENABLE_TEST_BUILD),yes)
TEST_DEPS += test-build
endif
TEST_DEPS += install installcheck
test: $(TEST_DEPS)
	@if [ -r $(TESTOUT)/regression.diffs ]; then cat $(TESTOUT)/regression.diffs; exit 1; fi

#
# verify-results: Safeguard for make results
#
# Checks if tests are passing before allowing make results to proceed
ifeq ($(PGXNTOOL_ENABLE_VERIFY_RESULTS),yes)
.PHONY: verify-results
ifeq ($(PGXNTOOL_VERIFY_RESULTS_MODE),pgtap)
verify-results:
	@$(PGXNTOOL_DIR)/verify-results-pgtap.sh $(TESTOUT)
else
verify-results:
	@if [ -r $(TESTOUT)/regression.diffs ]; then \
		echo "ERROR: Tests are failing. Cannot run 'make results'."; \
		echo "Fix test failures first, then run 'make results'."; \
		echo ""; \
		echo "See $(TESTOUT)/regression.diffs for details:"; \
		cat $(TESTOUT)/regression.diffs; \
		exit 1; \
	fi
endif
endif

# make results: runs the same steps as `make test` and copies all result files
# to expected.
# DO NOT RUN THIS UNLESS YOU'RE CERTAIN ALL YOUR TESTS ARE PASSING!
#
# Depends on $(TEST_DEPS) directly rather than on `test` itself: `test`'s own
# recipe now exits non-zero as soon as it sees a regression.diffs mismatch
# (see `test:` above), which would abort this chain before verify-results ever
# got a chance to inspect the diff and report it properly. verify-results (or
# the plain diffs check below, when disabled) is the one that's supposed to
# decide pass/fail here, not `test`.
#
# Dependency chain (verify-results: $(TEST_DEPS)) guarantees those complete
# before verify-results checks regression.diffs, even under make -j. Listing
# them as independent prerequisites of results would allow them to run
# concurrently, letting verify-results see stale state.
.PHONY: results
ifeq ($(PGXNTOOL_ENABLE_VERIFY_RESULTS),yes)
verify-results: $(TEST_DEPS)
results: verify-results
else
results: $(TEST_DEPS)
endif
	@mkdir -p $(TESTDIR)/expected
	@for f in $(TESTOUT)/results/*.out; do \
		[ -f "$$f" ] || continue; \
		cp "$$f" $(TESTDIR)/expected/$$(basename "$$f"); \
	done

# testdeps is a generic dependency target that you can add targets to
.PHONY: testdeps
testdeps: pgtap

#
# pg_tle support - Generate pg_tle registration SQL
#

# PGXNTOOL_CONTROL_FILES is defined above (for control.mk dependencies)
PGXNTOOL_EXTENSIONS = $(basename $(PGXNTOOL_CONTROL_FILES))

# Main target
# Depend on 'all' to ensure versioned SQL files are generated first
# Depend on control.mk (which defines EXTENSION__CURRENT_VERSION__FILES)
# Depend on control files explicitly so changes trigger rebuilds
# Generates all supported pg_tle versions for each extension, unless
# PGXNTOOL_PGTLE_VERSION is set on the command line to limit output to one
# range. Deliberately not named PGTLE_VERSION: make auto-imports same-named
# environment variables, and PGTLE_VERSION is a natural name for a CI job's
# "which pg_tle to test against" env var (see issue #78) -- that collided
# with this variable silently instead of erroring.
.PHONY: pgtle
pgtle: all control.mk $(PGXNTOOL_CONTROL_FILES)
	@$(foreach ext,$(PGXNTOOL_EXTENSIONS),\
		$(PGXNTOOL_DIR)/pgtle.sh --extension $(ext) $(if $(PGXNTOOL_PGTLE_VERSION),--pgtle-version $(PGXNTOOL_PGTLE_VERSION));)

#
# pg_tle installation support
#

# Check if pg_tle is installed and report version
# Only reports version if CREATE EXTENSION pg_tle has been run
# Errors if pg_tle extension is not installed
# Uses pgtle.sh to get version (avoids code duplication)
.PHONY: check-pgtle
check-pgtle:
	@echo "Checking pg_tle installation..."
	@PGTLE_VERSION=$$($(PGXNTOOL_DIR)/pgtle.sh --get-version 2>/dev/null); \
	if [ -n "$$PGTLE_VERSION" ]; then \
		echo "pg_tle extension version: $$PGTLE_VERSION"; \
		exit 0; \
	fi; \
	echo "ERROR: pg_tle extension is not installed" >&2; \
	echo "       Run 'CREATE EXTENSION pg_tle;' first" >&2; \
	exit 1

# Run pg_tle registration SQL files
# Requires pg_tle extension to be installed (checked via check-pgtle)
# Uses pgtle.sh to determine which version range directory to use
# Assumes PG* environment variables are configured
.PHONY: run-pgtle
run-pgtle: pgtle
	@$(PGXNTOOL_DIR)/pgtle.sh --run

# These targets ensure all the relevant directories exist
$(TESTDIR)/sql $(TESTDIR)/expected/ $(TESTOUT)/results/:
	@mkdir -p $@
# pg_regress aborts with "could not open file" if an expected output file is
# missing, so create empty placeholders for any test that lacks one.
$(TEST_RESULT_FILES): | $(TESTDIR)/expected/
	@# Create empty expected file so pg_regress doesn't abort with "file not found".
	@# pg_regress requires an expected/*.out file to exist for each test; without it
	@# it stops immediately rather than running the test and showing the diff.
	@touch $@

#
# test-build: Sanity check extension files in test/build/
#
# The sql/ subdirectory is generated - files are synced from test/build/*.sql.
# This directory should be in .gitignore and is cleaned by make clean.
#
ifeq ($(PGXNTOOL_ENABLE_TEST_BUILD),yes)
TEST_BUILD_SQL_DIR = $(TESTDIR)/build/sql
TEST_BUILD_REGRESS = $(sort $(notdir $(basename $(TEST_BUILD_SQL_FILES))))
.PHONY: test-build
test-build: install
	@$(PGXNTOOL_DIR)/run-test-build.sh $(TESTDIR)
	$(MAKE) -C . REGRESS="$(TEST_BUILD_REGRESS)" REGRESS_OPTS="--inputdir=$(TESTDIR)/build --outputdir=$(TESTDIR)/build" installcheck
	@if [ -r $(TESTDIR)/build/regression.diffs ]; then \
		echo "test-build failed - see $(TESTDIR)/build/regression.diffs"; \
		cat $(TESTDIR)/build/regression.diffs; \
		exit 1; \
	fi
endif


#
# DOC SUPPORT
#
ASCIIDOC_HTML += $(filter %.html,$(foreach ext,$(ASCIIDOC_EXTS),$(ASCIIDOC_FILES:.$(ext)=.html)))
DOCS_HTML += $(ASCIIDOC_HTML)

# General ASCIIDOC template. This will be used to create rules for all ASCIIDOC_EXTS
define ASCIIDOC_template
%.html: %.$(1)
ifeq (,$(strip $(ASCIIDOC)))
	$$(warning Could not find "asciidoc" or "asciidoctor". Add one of them to your PATH,)
	$$(warning or set ASCIIDOC to the correct location.)
	$$(error Could not build %$$@)
endif # ifeq ASCIIDOC
	$$(ASCIIDOC) $$(ASCIIDOC_FLAGS) $$<
endef # define ASCIIDOC_template

# Create the actual rules
$(foreach ext,$(ASCIIDOC_EXTS),$(eval $(call ASCIIDOC_template,$(ext))))

# Create the html target regardless of whether we have asciidoc, and make it a dependency of dist
html: $(ASCIIDOC_HTML)
dist: html

# But don't add it as an install or test dependency unless we do have asciidoc
ifneq (,$(strip $(ASCIIDOC)))

# Add HTML to DOCS for install, deduplicating against any HTML already picked
# up by the wildcard (e.g. pre-built HTML committed to the repo).
DOCS := $(sort $(filter-out $(ASCIIDOC_HTML),$(DOCS)) $(ASCIIDOC_HTML))

# Also need to add html as a dep to all (which will get picked up by install & installcheck
all: html

endif # ASCIIDOC

.PHONY: docclean
docclean:
	$(RM) $(DOCS_HTML)


#
# TAGGING SUPPORT
#
# Remote used for tag/rmtag/forcetag/dist. Override on the command line or in
# your Makefile if you push tags somewhere other than origin.
PGXN_REMOTE ?= origin

rmtag:
	git fetch $(PGXN_REMOTE) # Update our remotes
	@test -z "$$(git tag --list $(PGXNVERSION))" || git tag -d $(PGXNVERSION)
	@test -z "$$(git ls-remote --tags $(PGXN_REMOTE) $(PGXNVERSION) | grep -v '{}')" || git push --delete $(PGXN_REMOTE) $(PGXNVERSION)

tag:
	@test -z "$$(git status --porcelain)" || (echo 'Untracked changes!'; echo; git status; exit 1)
	@# Skip if tag already exists and points to HEAD
	@if git rev-parse $(PGXNVERSION) >/dev/null 2>&1; then \
		if [ "$$(git rev-parse $(PGXNVERSION))" = "$$(git rev-parse HEAD)" ]; then \
			echo "Tag $(PGXNVERSION) already exists at HEAD, skipping"; \
		else \
			echo "ERROR: Tag $(PGXNVERSION) exists but points to different commit" >&2; \
			exit 1; \
		fi; \
	else \
		git tag $(PGXNVERSION); \
	fi
	git push $(PGXN_REMOTE) $(PGXNVERSION)

.PHONY: forcetag
forcetag: rmtag tag

.PHONY: dist
dist: tag dist-only

dist-only:
	@# Check if .gitattributes exists but isn't committed
	@if [ -f .gitattributes ] && ! git ls-files --error-unmatch .gitattributes >/dev/null 2>&1; then \
		echo "ERROR: .gitattributes exists but is not committed to git." >&2; \
		echo "       git archive only respects export-ignore for committed files." >&2; \
		echo "       Please commit .gitattributes for export-ignore to take effect." >&2; \
		exit 1; \
	fi
	git archive --prefix=$(PGXN)-$(PGXNVERSION)/ -o ../$(PGXN)-$(PGXNVERSION).zip $(PGXNVERSION)

.PHONY: forcedist
forcedist: forcetag dist

# Target to list all targets
# http://stackoverflow.com/questions/4219255/how-do-you-get-the-list-of-targets-in-a-makefile
.PHONY: no_targets__ list
no_targets__:
list:
	sh -c "$(MAKE) -p no_targets__ | awk -F':' '/^[a-zA-Z0-9][^\$$#\/\\t=]*:([^=]|$$)/ {split(\$$1,A,/ /);for(i in A)print A[i]}' | grep -v '__\$$' | sort"

# To use this, do make print-VARIABLE_NAME
print-%	: ; $(info $* is $(flavor $*) variable set to "$($*)") @true


#
# subtree sync support
#
# All the real work (git subtree pull + update-setup-files.sh) lives in
# pgxntool/pgxntool-sync.sh so it can be run directly, without make. These
# targets are thin wrappers around that script.
#
# `make pgxntool-sync` pulls the latest released version from the canonical
# repository (the script's built-in default).
#
# `make pgxntool-sync-<name>` pulls from the "<repo> <ref>" defined by the
# pgxntool-sync-<name> variable, allowing any number of custom pull sources.
.PHONY: pgxntool-sync pgxntool-sync-%
pgxntool-sync:
	@pgxntool/pgxntool-sync.sh
pgxntool-sync-%:
	@pgxntool/pgxntool-sync.sh $($@)

# `make pgxntool-version` prints the version of the embedded pgxntool copy.
# Delegates to bin/version so it can be run without make too.
.PHONY: pgxntool-version
pgxntool-version:
	@$(PGXNTOOL_DIR)/bin/version

# DANGER! Use these with caution. They may add extra crap to your history and
# could make resolving merges difficult!
# `pgxntool-sync` (no suffix) already pulls the canonical release; these are the
# alternatives. `-master` pulls the bleeding edge; `-local*` pull from a sibling
# ../pgxntool checkout (not the same as PGXNTOOL_DIR!).
pgxntool-sync-master		:= https://github.com/Postgres-Extensions/pgxntool.git master
pgxntool-sync-local		:= ../pgxntool release
pgxntool-sync-local-master	:= ../pgxntool master

# PGXS doesn't provide any special support for distclean (it just depends on
# clean), so we roll our own. Files that should only be removed by distclean
# (not clean) are added to PGXNTOOL_distclean near their build rules above.
distclean:
	rm -f $(PGXNTOOL_distclean)

ifndef PGXNTOOL_NO_PGXS_INCLUDE

ifeq (,$(strip $(DOCS)))
DOCS =# Set to NUL so PGXS doesn't puke
endif

include $(PGXS)

# Override CONTRIB_TESTDB (set unconditionally by PGXS) with our unique database
# name. This must be after include $(PGXS) because PGXS uses = (not ?=).
# PGXS appends --dbname=$(CONTRIB_TESTDB) to REGRESS_OPTS, so overriding
# CONTRIB_TESTDB is the correct way to control the database name — adding our
# own --dbname would result in two --dbname flags passed to pg_regress.
CONTRIB_TESTDB = $(REGRESS_DBNAME)

# Clean generated sql/ directory for test-build
ifeq ($(PGXNTOOL_ENABLE_TEST_BUILD),yes)
.PHONY: clean-test-build
clean-test-build:
	rm -rf $(TEST_BUILD_SQL_DIR)
clean: clean-test-build
endif

#
# pgtap
#
# NOTE! This currently MUST be after PGXS! The problem is that
# $(DESTDIR)$(datadir) aren't being expanded. This can probably change after
# the META handling stuff is it's own makefile.
#
.PHONY: pgtap
installcheck: pgtap
pgtap: $(DESTDIR)$(datadir)/extension/pgtap.control

$(DESTDIR)$(datadir)/extension/pgtap.control:
	pgxn install pgtap --sudo

endif # fndef PGXNTOOL_NO_PGXS_INCLUDE

endif # ifndef PGXNTOOL_BASE_MK_INCLUDED
