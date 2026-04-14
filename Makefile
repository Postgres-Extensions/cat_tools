B = sql

testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this

include pgxntool/base.mk

LT95		 = $(call test, $(MAJORVER), -lt, 95)
LT93		 = $(call test, $(MAJORVER), -lt, 93)

$B:
	@mkdir -p $@

versioned_in = $(wildcard sql/*--*.sql.in)
versioned_out = $(subst sql/,$B/,$(subst .sql.in,.sql,$(versioned_in)))

# Pre-built historical install scripts (no .sql.in source available)
DATA += sql/cat_tools--0.1.0.sql sql/cat_tools--0.1.3.sql sql/cat_tools--0.1.4.sql
# Generated historical install scripts (built from .sql.in source)
DATA += $(versioned_out)

all: $B/cat_tools.sql $(versioned_out)
installcheck: $B/cat_tools.sql $(versioned_out)
EXTRA_CLEAN += $B/cat_tools.sql $(versioned_out)

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
ifeq ($(LT95),yes)
	pgxntool/safesed $@.tmp -E -e 's/(.*)-- SED: REQUIRES 9.5!/-- Requires 9.5: \1/'
else
	pgxntool/safesed $@.tmp -E -e 's/(.*)-- SED: PRIOR TO 9.5!/-- Not used prior to 9.5: \1/'
endif
ifeq ($(LT93),yes)
	pgxntool/safesed $@.tmp -E -e 's/(.*)-- SED: REQUIRES 9.3!/-- Requires 9.3: \1/'
else
	pgxntool/safesed $@.tmp -E -e 's/(.*)-- SED: PRIOR TO 9.3!/-- Not used prior to 9.3: \1/'
endif
	mv $@.tmp $@

# Support for upgrade test
#
# TODO: Instead of all of this stuff figure out how to pass something to
# pg_regress that will alter the behavior of the test instead.
TEST_BUILD_DIR = test/.build
testdeps: $(TEST_BUILD_DIR)/dep.mk $(TEST_BUILD_DIR)/active.sql
-include $(TEST_BUILD_DIR)/dep.mk

# Ensure dep.mk exists.
$(TEST_BUILD_DIR)/dep.mk: $(TEST_BUILD_DIR)
	echo 'TEST_LOAD_SOURCE = new' > $(TEST_BUILD_DIR)/dep.mk

.PHONY: set-test-new
set-test-new: $(TEST_BUILD_DIR)
	echo 'TEST_LOAD_SOURCE = new' > $(TEST_BUILD_DIR)/dep.mk

.PHONY: test-upgrade
set-test-upgrade: $(TEST_BUILD_DIR)
	echo 'TEST_LOAD_SOURCE = upgrade' > $(TEST_BUILD_DIR)/dep.mk


$(TEST_BUILD_DIR)/active.sql: $(TEST_BUILD_DIR)/dep.mk $(TEST_BUILD_DIR)/$(TEST_LOAD_SOURCE).sql 
	ln -sf $(TEST_LOAD_SOURCE).sql $@

$(TEST_BUILD_DIR)/upgrade.sql: test/load_upgrade.sql $(TEST_BUILD_DIR) old_version
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@

$(TEST_BUILD_DIR)/new.sql: test/load_new.sql $(TEST_BUILD_DIR)
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@

# TODO: figure out vpath
EXTRA_CLEAN += $(TEST_BUILD_DIR)/
$(TEST_BUILD_DIR):
	[ -d $@ ] || mkdir -p $@

.PHONY: old_version
old_version: $(DESTDIR)$(datadir)/extension/cat_tools--0.2.0.sql
$(DESTDIR)$(datadir)/extension/cat_tools--0.2.0.sql:
	pgxn install --unstable 'cat_tools=0.2.0'


.PHONY: clean_old_version
clean_old_version:
	pgxn uninstall --unstable 'cat_tools=0.2.0'
