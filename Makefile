testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this

# Versioned SQL is generated from .sql.in at build time. That generation and the
# DATA list that installs it live in sql.mk, which also owns
# `include pgxntool/base.mk` (base.mk has no include guard, so it must be
# included exactly once; sql.mk includes it at its top). sql.mk documents the
# GNU Make two-phase (parse vs. recipe) hazards involved (e.g.
# https://github.com/Postgres-Extensions/cat_tools/issues/28) and relies on
# base.mk/control.mk/PGXS vars (EXTENSION_VERSION_FILES, PG_CONFIG, MAJORVER,
# datadir, ...).
include sql.mk

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
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@.tmp
	mv $@.tmp $@

$(TEST_BUILD_DIR)/new.sql: test/load_new.sql $(TEST_BUILD_DIR)
	(echo @generated@ && cat $< && echo @generated@) | sed -e 's#@generated@#-- GENERATED FILE! DO NOT EDIT! See $<#' > $@.tmp
	mv $@.tmp $@

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
