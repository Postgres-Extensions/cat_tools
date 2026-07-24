# Parent Makefile for all linters.
# Add new linter subdirectories to LINTERS as they are created.

LINTERS = sql

.PHONY: test
test:
	for linter in $(LINTERS); do $(MAKE) -C $$linter test || exit 1; done
