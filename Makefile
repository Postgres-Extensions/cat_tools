B = sql

testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this

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

# Generate the canonical set of pg_class.relkind values from the server headers
# we are building against, for the relkind drift check in test/sql/relation__.sql.
# Regenerated on every test run so it always tracks the active PostgreSQL
# version; the output is gitignored (per-version). When postgresql-server-dev-NN
# is not installed the script emits an empty view so `make test` still works
# locally -- but see check-relkind-source below, which CI runs so a missing
# header can never let the drift check pass silently.
RELKIND_SRC = test/generated/pg_class_relkinds.sql
.PHONY: gen-relkinds
gen-relkinds: test/gen-relkinds.sh | test/generated
	test/gen-relkinds.sh "$$($(PG_CONFIG) --includedir-server)/catalog/pg_class.h" > $(RELKIND_SRC)
test/generated:
	@mkdir -p $@
testdeps: gen-relkinds
EXTRA_CLEAN += $(RELKIND_SRC)

# Guard for CI: fail if the relkind source has no relkinds (server headers
# missing), so the drift check in test/sql/relation__.sql cannot silently pass
# on an empty view. CI runs `make check-relkind-source` before `make test` on
# every PostgreSQL version; local `make test` stays lenient.
.PHONY: check-relkind-source
check-relkind-source: gen-relkinds
	@grep -q 'RELKIND_' $(RELKIND_SRC) || { \
	  echo "ERROR: $(RELKIND_SRC) contains no relkinds. postgresql-server-dev-NN"; \
	  echo "       (catalog/pg_class.h) is not installed, so the relkind drift"; \
	  echo "       check would pass without actually running. Install it."; \
	  exit 1; \
	}
	@echo "check-relkind-source: $(RELKIND_SRC) is populated"

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
