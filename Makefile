B = sql

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
# spawns inherit the environment, so PGOPTIONS reaches load.sql; the default
# (unset) reads as fresh.
#
# The upgrade must be committed (which is why it lives in test/install, not in
# deps.sql's per-test transaction): the update to the current version runs
# ALTER TYPE ... ADD VALUE, and a newly added enum value cannot be USED in the
# transaction that added it (55P04). See test/install/load.sql.
#
# Upgrade mode requires PG12+ (ALTER TYPE ... ADD VALUE cannot run in a
# transaction at all before PG12); CI restricts it accordingly.
ifeq ($(TEST_LOAD_SOURCE),upgrade)
export PGOPTIONS := $(PGOPTIONS) -c cat_tools.test_load_mode=upgrade
endif

# Convenience wrapper: `make test-update` == `make test TEST_LOAD_SOURCE=upgrade`.
# Must recurse (a fresh $(MAKE)) rather than depend on `test`, so the parse-time
# TEST_LOAD_SOURCE conditional above re-evaluates with upgrade set.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=upgrade

include pgxntool/base.mk

LT95		 = $(call test, $(MAJORVER), -lt, 95)
LT93		 = $(call test, $(MAJORVER), -lt, 93)

$B:
	@mkdir -p $@

versioned_in = $(wildcard sql/*--*.sql.in)
versioned_out = $(subst sql/,$B/,$(subst .sql.in,.sql,$(versioned_in)))
# Upgrade scripts (*--*--*.sql) are already added by base.mk via $(wildcard sql/*--*--*.sql).
upgrade_scripts_out = $(subst sql/,$B/,$(subst .sql.in,.sql,$(wildcard sql/*--*--*.sql.in)))

# Pre-built historical install scripts (no .sql.in source available)
DATA += sql/cat_tools--0.1.0.sql sql/cat_tools--0.1.3.sql sql/cat_tools--0.1.4.sql sql/cat_tools--0.1.5.sql
# Generated install scripts (built from .sql.in source).
# Exclude EXTENSION_VERSION_FILES (managed by control.mk) and upgrade scripts
# ($(upgrade_scripts_out), already handled by base.mk) to avoid duplicates.
DATA += $(filter-out $(EXTENSION_VERSION_FILES) $(upgrade_scripts_out), $(versioned_out))

all: $B/cat_tools.sql $(versioned_out)
installcheck: $B/cat_tools.sql $(versioned_out)
EXTRA_CLEAN += $B/cat_tools.sql $(versioned_out)

# Clean the cruft pg_regress writes into test/install/ (the self-comparing
# result .out and its diff), which is listed in test/install/.gitignore.
EXTRA_CLEAN += $(addprefix test/install/,$(shell grep -v '^\#' test/install/.gitignore 2>/dev/null))

# Generate the canonical set of pg_class.relkind values from the server headers
# we are building against, for the relkind drift check in test/sql/relation__.sql.
# The output is gitignored (per-version). When postgresql-server-dev-NN is not
# installed the script emits an empty view so `make test` still works locally;
# CI runs check-relkind-source (below) so a missing header can never let the
# drift check pass silently, and `make test` warns about it locally.
RELKIND_SRC = test/generated/pg_class_relkinds.sql

# Absolute path to the header we extract relkinds from. Computed each `make`;
# it changes when we build against a different PostgreSQL (pg_config differs).
RELKIND_HEADER := $(shell $(PG_CONFIG) --includedir-server)/catalog/pg_class.h

# Stamp recording the header path. FORCE runs the recipe every time, but it only
# rewrites the stamp (bumping its mtime) when the path actually changed, so the
# source is regenerated after a PostgreSQL-version switch even though the old
# header file itself is untouched.
RELKIND_STAMP = test/generated/.relkind-header-path

.PHONY: FORCE
FORCE:

$(RELKIND_STAMP): FORCE | test/generated
	@echo '$(RELKIND_HEADER)' | cmp -s - "$@" 2>/dev/null || echo '$(RELKIND_HEADER)' > "$@"

# Real file target (not .PHONY): regenerate only when the generator, the header
# file, or the header path change -- not on every `make`. $(wildcard ...) yields
# no prereq (rather than an error) when the header is absent, in which case
# gen-relkinds.sh emits an empty view.
$(RELKIND_SRC): test/gen-relkinds.sh $(RELKIND_STAMP) $(wildcard $(RELKIND_HEADER)) | test/generated
	test/gen-relkinds.sh "$(RELKIND_HEADER)" > "$@"

.PHONY: gen-relkinds
gen-relkinds: $(RELKIND_SRC)

# The `| test/generated` on the two targets above is an ORDER-ONLY prerequisite:
# the generated files live in this directory, which must exist before we write
# them, but we must NOT rebuild them just because the directory changed. A
# directory's mtime bumps every time any file is added to or removed from it, so
# as a normal prerequisite it would force needless regeneration on every run.
# Listing it after `|` means "ensure it exists, but its timestamp is not a
# rebuild trigger."
test/generated:
	@mkdir -p $@
testdeps: $(RELKIND_SRC)
EXTRA_CLEAN += $(RELKIND_SRC) $(RELKIND_STAMP)

# Guard for CI: fail if the relkind source has no relkinds (server headers
# missing), so the drift check in test/sql/relation__.sql cannot silently pass
# on an empty view. CI runs `make check-relkind-source` before `make test` on
# every PostgreSQL version; local `make test` stays lenient (see
# warn-relkind-source).
.PHONY: check-relkind-source
check-relkind-source: $(RELKIND_SRC)
	@grep -q 'RELKIND_' $(RELKIND_SRC) || { \
	  echo "ERROR: PostgreSQL catalog header not found at"; \
	  echo "         $(RELKIND_HEADER)"; \
	  echo "       so the relkind drift check in test/sql/relation__.sql would"; \
	  echo "       pass without running. Install this PostgreSQL version's server"; \
	  echo "       development headers so that path exists."; \
	  exit 1; \
	}
	@echo "check-relkind-source: $(RELKIND_SRC) is populated"

# Non-fatal counterpart, run at the end of `make test`: warn (do not fail) when
# the drift source is empty because the server headers are missing, so a local
# run without postgresql-server-dev-NN makes clear the drift check did not run.
# Listed as a `test` prerequisite after base.mk's, so it runs once tests are done.
.PHONY: warn-relkind-source
warn-relkind-source: $(RELKIND_SRC)
	@grep -q 'RELKIND_' $(RELKIND_SRC) || echo "WARNING: PostgreSQL catalog header not found at $(RELKIND_HEADER); the relkind drift check in test/sql/relation__.sql did NOT run. Install this PostgreSQL version's server development headers to enable it."
test: warn-relkind-source

# Temporary ugly hack for 9.x — remove these two blocks when 9.x support is dropped.
# $@ is deferred via = and expands to the target name at recipe time.
ifeq ($(LT95),yes)
_sql_sed_95 = pgxntool/safesed $@.tmp -E -e 's/(.*)-- SED: REQUIRES 9\.5!/-- Requires 9.5: \1/'
else
_sql_sed_95 = pgxntool/safesed $@.tmp -E -e 's/(.*)-- SED: PRIOR TO 9\.5!/-- Not used prior to 9.5: \1/'
endif
ifeq ($(LT93),yes)
_sql_sed_93 = pgxntool/safesed $@.tmp -E -e 's/(.*)-- SED: REQUIRES 9\.3!/-- Requires 9.3: \1/'
else
_sql_sed_93 = pgxntool/safesed $@.tmp -E -e 's/(.*)-- SED: PRIOR TO 9\.3!/-- Not used prior to 9.3: \1/'
endif

# Apply all version-conditional SED markers to $@.tmp.
# 9.x handled by the above variables (temporary hack, to be removed with 9.x support).
# 10+ handled generically via awk: REQUIRES N → commented if MAJORVER < N*10;
#                                   PRIOR TO N → commented if MAJORVER >= N*10.
# IMPORTANT: Use only POSIX awk features here (no gawk extensions like gensub(),
# 3-arg match(), etc.) — awk availability and compatibility across platforms is
# the whole reason this approach was chosen over sed.
define _apply_version_seds
	$(_sql_sed_95)
	$(_sql_sed_93)
	awk -v mv=$(MAJORVER) '\
		/-- SED: REQUIRES [1-9][0-9]+!/ {t=$$0; sub(/.*REQUIRES /,"",t); sub(/!.*/,"",t); if(mv<t*10) $$0="-- Requires "t": "$$0}\
		/-- SED: PRIOR TO [1-9][0-9]+!/ {t=$$0; sub(/.*PRIOR TO /,"",t); sub(/!.*/,"",t); if(mv>=t*10) $$0="-- Not used prior to "t": "$$0}\
		{print}' $@.tmp > $@.tmp2 && mv $@.tmp2 $@.tmp
endef

# TODO: refactor the version stuff into a function
#
# This initially creates $@.tmp before moving it into place atomically. That's
# important to make the use of .PRECIOUS safe, which is necessary for
# watch-make not to freak out.
#
# Actually, that doesn't even fix it. TODO: Figure out why this breaks watch-make.
#
# Make sure not to insert blank lines here; everything needs to be part of the cat_tools.sql recipe!
#.PRECIOUS: $B/cat_tools.sql
$B/%.sql: sql/%.sql.in pgxntool/safesed
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@.tmp
	$(_apply_version_seds)
	mv $@.tmp $@

# Generate the current version's .sql.in by copying the base source.
# This intermediate file is then processed by the pattern rule above to produce
# the final .sql with version-conditional SED substitutions applied.
# (EXTENSION_VERSION_FILES is just sql/cat_tools--<current version>.sql)
$(EXTENSION_VERSION_FILES:.sql=.sql.in): sql/cat_tools.sql.in cat_tools.control
	cp $< $@

# Override the control.mk rule that builds EXTENSION_VERSION_FILES directly from
# cat_tools.sql (bypassing SED processing). Instead, build from the .sql.in above
# so that version-conditional substitutions (-- SED: REQUIRES X!) are applied.
# Note: GNU Make will emit "overriding recipe" for this target — that is expected.
$(EXTENSION_VERSION_FILES): $(EXTENSION_VERSION_FILES:.sql=.sql.in) pgxntool/safesed
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@.tmp
	$(_apply_version_seds)
	mv $@.tmp $@


.PHONY: old_version
old_version: $(DESTDIR)$(datadir)/extension/cat_tools--0.2.0.sql
$(DESTDIR)$(datadir)/extension/cat_tools--0.2.0.sql:
	pgxn install --unstable 'cat_tools=0.2.0'


.PHONY: clean_old_version
clean_old_version:
	pgxn uninstall --unstable 'cat_tools=0.2.0'
