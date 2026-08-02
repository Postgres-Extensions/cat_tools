#
# sql.mk -- versioned SQL generation and everything that depends on it.
#
# Owns `include pgxntool/base.mk` (which pulls in control.mk and, at its end,
# PGXS), included at the top of this file before the DATA/rules below. The
# Makefile includes THIS file (once) and does NOT include base.mk itself:
# base.mk has no include guard, so a second include causes "overriding recipe"
# errors (upstream: https://github.com/Postgres-Extensions/pgxntool/issues/50).
# The code below uses vars from those includes: EXTENSION__CURRENT_VERSION__FILES
# (control.mk); PG_CONFIG / MAJORVER / $(call test,...) (base.mk); datadir (PGXS).
#
# ============================================================================
# GNU Make is TWO-PHASE, and we GENERATE the .sql we install -- beware.
# ============================================================================
# Phase 1 (parse) expands every $(wildcard ...) and CACHES directory listings
# before any recipe runs. Phase 2 (recipes) then generates our versioned SQL
# (sql/cat_tools--X.Y.Z.sql install scripts and sql/cat_tools--A.B.C--X.Y.Z.sql
# update scripts) from .sql.in sources. Those generated .sql are gitignored (see
# sql/.gitignore) and absent on a clean tree at parse time, so any parse-time
# $(wildcard) over them comes up short -- and the cached listing means Make never
# notices them later either.
#
# https://github.com/Postgres-Extensions/cat_tools/issues/28 is the canonical
# symptom: base.mk seeds DATA with $(wildcard sql/*--*--*.sql), a phase-1 glob
# that misses our generated update scripts on a clean tree, so `make install`
# skips them and a later `ALTER EXTENSION cat_tools UPDATE` fails with "no update
# path".
#
# The rule this file follows: glob what git TRACKS; name-DERIVE what we generate.
# We build the install/update lists from the .sql.in SOURCE names (present at
# parse time), not from the generated .sql, then add those names to DATA and
# $(sort) to dedup against base.mk's own wildcard. Such lists are parse-stable:
# identical on a clean tree and a built tree.
# ============================================================================

# See header: base.mk must be included exactly once, before the DATA/rules below.
include pgxntool/base.mk

LT95		 = $(call test, $(MAJORVER), -lt, 95)
LT93		 = $(call test, $(MAJORVER), -lt, 93)

#
# Parse-stable lists derived from the .sql.in SOURCES (see header). versioned_in
# globs the committed .sql.in; _out renames each to the .sql we generate.
#
versioned_in = $(wildcard sql/*--*.sql.in)
versioned_out = $(subst .sql.in,.sql,$(versioned_in))
# base.mk also seeds the update scripts via $(wildcard sql/*--*--*.sql), but that
# glob misses the generated ones on a clean tree (see header), so add by name.
upgrade_scripts_out = $(subst .sql.in,.sql,$(wildcard sql/*--*--*.sql.in))

#
# Historical install scripts committed directly as .sql with no .sql.in (the
# frozen cat_tools--0.1.* set; see sql/.gitignore). Globbing committed files is
# safe. Derive rather than hardcode: take every install-shaped .sql, then drop
# the update scripts and everything we generate from .sql.in. Parse-stable (the
# subtracted names are name-derived), and picks up new historical files auto.
historical_installs = $(filter-out $(versioned_out) $(wildcard sql/*--*--*.sql), $(wildcard sql/*--*.sql))

#
# DATA -- the INSTALL manifest: what `make install` copies into the extension
# dir. Installed != committed. The versioned .sql (install and update scripts)
# are BUILT from the committed .sql.in at build time and installed, but are
# gitignored, not tracked -- only the .sql.in are. The historical
# cat_tools--0.1.*.sql are the exception: committed directly (no .sql.in source).
# base.mk only seeds DATA; we append here.
#
DATA += $(historical_installs)
# Generated install scripts, minus the current-version file
# (EXTENSION__CURRENT_VERSION__FILES, from control.mk) and the update scripts.
DATA += $(filter-out $(EXTENSION__CURRENT_VERSION__FILES) $(upgrade_scripts_out), $(versioned_out))
# Generated update scripts: base.mk's parse-time wildcard misses these on a clean
# tree (see header), so add by name.
DATA += $(upgrade_scripts_out)
# Dedup against base.mk's wildcard on trees where the generated .sql already
# exist (also gives a stable order).
DATA := $(sort $(DATA))

all: sql/cat_tools.sql $(versioned_out)
installcheck: sql/cat_tools.sql $(versioned_out)
EXTRA_CLEAN += sql/cat_tools.sql $(versioned_out)

#
# relkind drift source generation
#
# Generate the canonical set of pg_class.relkind values from the server headers
# we are building against, for the relkind drift check in test/sql/relation__.sql.
# The output is gitignored (per-version). When postgresql-server-dev-NN is not
# installed the script emits an empty view so `make test` still works locally;
# CI runs check-relkind-source (below) so a missing header can never let the
# drift check pass silently, and `make test` warns about it locally.
RELKIND_SRC = test/.generated/pg_class_relkinds.sql

# Absolute path to the header we extract relkinds from. Computed each `make`;
# it changes when we build against a different PostgreSQL (pg_config differs).
RELKIND_HEADER := $(shell $(PG_CONFIG) --includedir-server)/catalog/pg_class.h

# Stamp recording the header path. FORCE runs the recipe every time, but it only
# rewrites the stamp (bumping its mtime) when the path actually changed, so the
# source is regenerated after a PostgreSQL-version switch even though the old
# header file itself is untouched. This is the same "name-derive the source"
# trick as versioned_out, but for a source (a server header) that lives OUTSIDE
# the tree: we cannot glob it into the dependency graph reliably, so we track its
# PATH in a committed-shaped stamp file instead.
RELKIND_STAMP = test/.generated/.relkind-header-path

# Directory the generated files live in. It is listed as an ORDER-ONLY
# prerequisite (after `|`) on the stamp and source recipes below: the directory
# must exist before we write into it, but we must NOT rebuild those files just
# because the directory changed. A directory's mtime bumps every time a file is
# added to or removed from it, so as a normal prerequisite it would force
# needless regeneration on every run; after `|` it means "ensure it exists, but
# its timestamp is not a rebuild trigger."
test/.generated:
	@mkdir -p $@

.PHONY: FORCE
FORCE:

$(RELKIND_STAMP): FORCE | test/.generated
	@echo '$(RELKIND_HEADER)' | cmp -s - "$@" 2>/dev/null || echo '$(RELKIND_HEADER)' > "$@"

# Real file target (not .PHONY): regenerate only when the generator, the header
# file, or the header path change -- not on every `make`. $(wildcard ...) yields
# no prereq (rather than an error) when the header is absent, in which case
# gen-relkinds.sh emits an empty view.
$(RELKIND_SRC): test/gen-relkinds.sh $(RELKIND_STAMP) $(wildcard $(RELKIND_HEADER)) | test/.generated
	test/gen-relkinds.sh "$(RELKIND_HEADER)" > "$@"

.PHONY: gen-relkinds
gen-relkinds: $(RELKIND_SRC)

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

#
# Versioned-SQL generation from .sql.in
#
# 9.x version-conditional markers (dotted, e.g. -- SED: REQUIRES/PRIOR TO 9.5!)
# are handled by these two safesed blocks; 10+ (two-digit) markers by the awk in
# _apply_version_seds. The two sets are disjoint -- the awk's [1-9][0-9]+ can't
# match a dotted "9.5" -- and the sources still use the 9.x markers, so both are
# needed. Remove these blocks only once the sources drop all 9.x markers.
#
# FUTURE CLEANUP: once support for the relevant old PG versions is dropped, a
# .sql.in whose only version-conditional content targets those versions can be
# frozen to a raw committed .sql (dropping its .sql.in and thus its share of this
# processing chain). Precedent: the historical cat_tools--0.1.*.sql are already
# committed raw, with no .sql.in source.
#
# $@ is deferred (via =) and expands to the target name at recipe time.
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

# Apply all version-conditional SED markers to $@.tmp: 9.x via the safesed vars
# above; 10+ generically via awk (REQUIRES N -> commented if MAJORVER < N*10;
# PRIOR TO N -> commented if MAJORVER >= N*10). POSIX awk only (no gawk
# extensions like gensub() / 3-arg match()) -- portability is why this uses awk.
define _apply_version_seds
	$(_sql_sed_95)
	$(_sql_sed_93)
	awk -v mv=$(MAJORVER) '\
		/-- SED: REQUIRES [1-9][0-9]+!/ {t=$$0; sub(/.*REQUIRES /,"",t); sub(/!.*/,"",t); if(mv<t*10) $$0="-- Requires "t": "$$0}\
		/-- SED: PRIOR TO [1-9][0-9]+!/ {t=$$0; sub(/.*PRIOR TO /,"",t); sub(/!.*/,"",t); if(mv>=t*10) $$0="-- Not used prior to "t": "$$0}\
		{print}' $@.tmp > $@.tmp2 && mv $@.tmp2 $@.tmp
endef

# ----------------------------------------------------------------------------
# Two .sql.in sources feed the same .sql.in -> .sql transform below (wrap with
# @generated@ markers, then _apply_version_seds), producing two different
# targets:
#
#   sql/cat_tools.sql.in (hand-maintained master, committed)
#     --pattern rule-->  sql/cat_tools.sql
#
#   sql/cat_tools.sql.in
#     --copy rule, tags @generated@ as "VERSIONED FILE!"-->
#       sql/cat_tools--X.Y.Z.sql.in (committed per-version snapshot; frozen
#       once released, see CLAUDE.md's SQL file conventions)
#         --override rule, same transform as the pattern rule-->
#           sql/cat_tools--X.Y.Z.sql = $(EXTENSION__CURRENT_VERSION__FILES)
#           (what CREATE EXTENSION actually installs)
#
# The bottom (override) rule can't just be left to the sql/%.sql pattern rule
# matching it: control.mk (auto-generated by pgxntool from cat_tools.control,
# see pgxntool/base.mk) already defines its OWN recipe for
# $(EXTENSION__CURRENT_VERSION__FILES) -- straight from cat_tools.sql, no .sql.in layer,
# no version seds -- and GNU Make always prefers an explicit rule over a
# pattern rule for the same target. Overriding it here is the only way to
# route that target through the same .sql.in / version-sed pipeline as
# everything else; its "overriding recipe" warning is expected. Both final
# steps build $@.tmp then move it into place atomically.
#
# TODO: refactor the version handling into a function.
# ----------------------------------------------------------------------------

# @generated@ becomes the "-- GENERATED FILE! DO NOT EDIT!" marker below via a
# plain, unanchored substring match -- it also fires on a handful of
# coincidental @generated@ occurrences inside real-code comments in
# cat_tools.sql.in, which is harmless (already inside a -- comment).
sql/%.sql: sql/%.sql.in pgxntool/safesed
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@.tmp
	$(_apply_version_seds)
	mv $@.tmp $@

# Appends " VERSIONED FILE!" after every @generated@ occurrence; the pattern
# rule above resolves the leading @generated@ either way, so the tag rides
# through into the final marker text untouched.
$(EXTENSION__CURRENT_VERSION__FILES:.sql=.sql.in): sql/cat_tools.sql.in cat_tools.control
	sed -e 's/@generated@/@generated@ VERSIONED FILE!/' $< > $@

# See the overview above for why this duplicates the pattern rule's recipe.
$(EXTENSION__CURRENT_VERSION__FILES): $(EXTENSION__CURRENT_VERSION__FILES:.sql=.sql.in) pgxntool/safesed
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@.tmp
	$(_apply_version_seds)
	mv $@.tmp $@
