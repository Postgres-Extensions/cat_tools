# lint.mk — shared Make fragment that adds a `lint` target to any extension.
#
# Include from an extension Makefile (one level below the repo root):
#
#   include ../lint/lint.mk
#
# Provides:
#   make lint   — run sql-lint on all SQL we own under the extension dir (sql/ and
#                 test/, or LINT_TARGETS if set). sql-lint skips vendored trees
#                 (deps/, pgxntool/) and auto-generated files (e.g.
#                 sql/<ext>--<ver>.sql).
#
# Set LINT_TARGETS before this include to lint a different set of paths, e.g.
# to exclude frozen version-snapshot files that are never hand-edited:
#
#   LINT_TARGETS = sql/cat_tools.sql.in sql/omit_column.sql test/
#   include lint/lint.mk

# Resolve the repo root relative to this file's location (lint/ is one level
# below root, so go up one more).
_LINT_MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
_REPO_ROOT   := $(abspath $(_LINT_MK_DIR)/..)
SQL_LINT     := $(_REPO_ROOT)/lint/sql/bin/sql-lint

LINT_TARGETS ?= sql/ test/

.PHONY: lint
lint:
	$(SQL_LINT) $(LINT_TARGETS)
