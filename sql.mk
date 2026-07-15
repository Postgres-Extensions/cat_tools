#
# sql.mk -- versioned SQL generation, and everything that depends on it.
#
# Included by Makefile AFTER `include pgxntool/base.mk` (which in turn includes
# control.mk and, at its very end, PGXS). Everything here therefore relies on
# variables/functions defined by those: EXTENSION_VERSION_FILES (control.mk),
# PG_CONFIG / MAJORVER / the $(call test,...) helper (base.mk), and datadir etc.
# (PGXS). Do NOT include this before base.mk.
#
# ============================================================================
# CRITICAL: GNU Make is a TWO-PHASE tool, and we GENERATE the files we install.
# ============================================================================
#
# Make runs in two distinct phases:
#
#   Phase 1 (parse / "immediate"): Make reads every makefile top to bottom,
#     expands all `$(wildcard ...)` calls, evaluates `:=` assignments and every
#     immediately-expanded reference, resolves `ifeq`/`ifdef`, and builds the
#     dependency graph. Crucially, Make also CACHES directory listings during
#     this phase. NO recipes have run yet.
#
#   Phase 2 (recipe execution / "deferred"): only now does Make run recipes to
#     bring targets up to date, expanding recursively-defined (`=`) variables
#     and automatic variables ($@, $<, ...) as each recipe fires.
#
# We build our versioned SQL (`sql/cat_tools--X.Y.Z.sql` install scripts and
# `sql/cat_tools--A.B.C--X.Y.Z.sql` update scripts) from `.sql.in` SOURCES during
# phase 2 (the pattern rule near the bottom of this file). The generated `.sql`
# are gitignored (see sql/.gitignore) and simply DO NOT EXIST on a clean tree
# when the makefile is parsed.
#
# That is the trap: any `$(wildcard sql/...*.sql)` written to enumerate the
# generated output is expanded in phase 1, BEFORE phase 2 creates those files.
# On a clean tree it sees the pre-generation state (the files are absent) and
# the cached directory listing means it will not notice them later either. So a
# parse-time glob over generated files silently comes up short.
#
# #28 is the canonical symptom, but it is a GENERAL hazard -- treat every
# parse-time reference to generated output with suspicion:
#
#   * DATA is a PGXS variable (NOT one pgxntool owns). base.mk merely SEEDS it
#     with `$(EXTENSION_VERSION_FILES) $(wildcard sql/*--*--*.sql)`. That
#     `$(wildcard sql/*--*--*.sql)` is a phase-1 glob over update scripts -- most
#     of which we generate. On a fresh build it therefore cannot see our
#     generated update scripts, so `make install` never copies them, and a later
#     `ALTER EXTENSION cat_tools UPDATE` fails with "no update path" (#28).
#
# HOW THIS FILE SIDESTEPS IT (the general recipe):
#
#   Do not derive lists from the GENERATED files. Derive them from the `.sql.in`
#   SOURCE names, which DO exist at parse time, and map source -> output by name
#   (see versioned_out / upgrade_scripts_out below). Those lists are "parse
#   stable": identical on a clean tree and on a fully built tree. We then feed
#   the generated names into DATA explicitly and `$(sort)` to dedup against
#   base.mk's own wildcard on trees where the .sql happen to already be present.
#
#   Globbing COMMITTED files at parse time is fine -- they exist before phase 2
#   (see historical_installs below, and the sql/*--*--*.sql seed for committed
#   update scripts). The rule of thumb: glob what git tracks; name-derive what
#   we generate.
#
#   The relkind generator uses the same idea with a header-path STAMP file
#   instead of a source list, because its "source" is a server header outside
#   the tree (see RELKIND_STAMP below).
# ============================================================================

B = sql

$B:
	@mkdir -p $@

LT95		 = $(call test, $(MAJORVER), -lt, 95)
LT93		 = $(call test, $(MAJORVER), -lt, 93)

#
# Parse-stable name lists, derived from the .sql.in SOURCES (see header above).
# versioned_in globs the .sql.in (committed -> present at parse time); the
# _out lists just rename those to the .sql we generate from them. (B = sql, so
# the sql/ -> $B/ subst is a no-op today, but keeps the mapping explicit.)
#
versioned_in = $(wildcard sql/*--*.sql.in)
versioned_out = $(subst sql/,$B/,$(subst .sql.in,.sql,$(versioned_in)))
# Update scripts (*--*--*.sql) are also seeded by base.mk via
# $(wildcard sql/*--*--*.sql); we add these generated ones explicitly below
# because that base.mk wildcard cannot see them on a clean tree (see #28).
upgrade_scripts_out = $(subst sql/,$B/,$(subst .sql.in,.sql,$(wildcard sql/*--*--*.sql.in)))

#
# Historical install scripts committed directly as .sql with NO .sql.in source
# (the frozen cat_tools--0.1.* set; see sql/.gitignore). These are COMMITTED, so
# globbing them at parse time is SAFE. We do NOT hardcode the version list:
# start from every install-shaped .sql present (`sql/*--*.sql`, which a glob's
# `*` also lets match the two-`--` update scripts), then remove
#   * the update scripts (`sql/*--*--*.sql`, committed and/or generated), and
#   * everything we generate from .sql.in ($(versioned_out)).
# What remains is exactly the committed historical install scripts -- and the
# result is identical on a clean tree and a built tree (the generated names we
# subtract are name-derived, not glob-derived), so it is parse-stable. New
# historical files (should any ever appear) are picked up automatically.
historical_installs = $(filter-out $(versioned_out) $(wildcard sql/*--*--*.sql), $(wildcard sql/*--*.sql))

#
# DATA -- what `make install` copies. See the header: DATA is a PGXS variable
# that base.mk only seeds; we append the rest here.
#
DATA += $(historical_installs)
# Generated install scripts (from .sql.in), minus the current-version file
# (EXTENSION_VERSION_FILES, managed by control.mk) and the update scripts.
DATA += $(filter-out $(EXTENSION_VERSION_FILES) $(upgrade_scripts_out), $(versioned_out))
# Generated update scripts (from .sql.in). base.mk's parse-time
# $(wildcard sql/*--*--*.sql) misses these on a clean tree (#28), so add them by
# name (parse-stable) here.
DATA += $(upgrade_scripts_out)
# $(sort) dedups against base.mk's wildcard on trees where the generated .sql
# already exist (and gives a stable order).
DATA := $(sort $(DATA))

all: $B/cat_tools.sql $(versioned_out)
installcheck: $B/cat_tools.sql $(versioned_out)
EXTRA_CLEAN += $B/cat_tools.sql $(versioned_out)

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
