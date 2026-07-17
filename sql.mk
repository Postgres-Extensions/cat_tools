#
# sql.mk -- versioned SQL generation and everything that depends on it.
#
# Owns `include pgxntool/base.mk` (which pulls in control.mk and, at its end,
# PGXS), included at the top of this file before the DATA/rules below. The
# Makefile includes THIS file (once) and does NOT include base.mk itself:
# base.mk has no include guard, so a second include causes "overriding recipe"
# errors (upstream: https://github.com/Postgres-Extensions/pgxntool/issues/50).
# The code below uses vars from those includes: EXTENSION_VERSION_FILES
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
# Generated install scripts, minus the current-version file (EXTENSION_VERSION_
# FILES, from control.mk) and the update scripts.
DATA += $(filter-out $(EXTENSION_VERSION_FILES) $(upgrade_scripts_out), $(versioned_out))
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

# The recipe builds $@.tmp then moves it into place atomically.
# TODO: refactor the version handling into a function.
sql/%.sql: sql/%.sql.in pgxntool/safesed
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@.tmp
	$(_apply_version_seds)
	mv $@.tmp $@

# Make the current version's .sql.in by copying the base source; the pattern
# rule above then turns it into the final .sql with SED substitutions applied.
# (EXTENSION_VERSION_FILES is just sql/cat_tools--<current version>.sql)
$(EXTENSION_VERSION_FILES:.sql=.sql.in): sql/cat_tools.sql.in cat_tools.control
	cp $< $@

# Override control.mk's rule (which builds EXTENSION_VERSION_FILES straight from
# cat_tools.sql, skipping SED) so we build from the .sql.in above instead, with
# version-conditional substitutions applied. GNU Make's "overriding recipe"
# warning for this target is expected.
$(EXTENSION_VERSION_FILES): $(EXTENSION_VERSION_FILES:.sql=.sql.in) pgxntool/safesed
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@.tmp
	$(_apply_version_seds)
	mv $@.tmp $@
