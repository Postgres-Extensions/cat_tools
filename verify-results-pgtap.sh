#!/usr/bin/env bash
# pgxntool/verify-results-pgtap.sh - Check pgtap results before 'make results'
#
# Scans pgtap output files for failures and plan mismatches, then checks
# regression.diffs as a fallback. Exits non-zero if any problems are found.
#
# Usage: verify-results-pgtap.sh TESTOUT
#
# Called by the verify-results target in base.mk (pgtap mode).

set -e

TESTOUT="${1:?Usage: verify-results-pgtap.sh TESTOUT}"

# Check for pgtap failures in result files (excluding TODO items)
failed=0
for f in "$TESTOUT"/results/*.out; do
	[ -f "$f" ] || continue
	if grep -q '^not ok' "$f"; then
		notok=$(grep '^not ok' "$f" | grep -v '# TODO' || true)
		if [ -n "$notok" ]; then
			echo "ERROR: pgtap failure detected in $f"
			echo "$notok"
			failed=1
		fi
	fi
	if grep -q 'Looks like you planned' "$f"; then
		echo "ERROR: pgtap plan mismatch in $f"
		grep 'Looks like you planned' "$f"
		failed=1
	fi
done
if [ $failed -ne 0 ]; then
	echo
	echo "pgtap failures detected. Cannot run 'make results'."
	exit 1
fi

# Also check regression.diffs (output mismatch even if pgtap all passed)
if [ -r "$TESTOUT/regression.diffs" ]; then
	echo "ERROR: Tests are failing. Cannot run 'make results'."
	echo "Fix test failures first, then run 'make results'."
	echo
	echo "See $TESTOUT/regression.diffs for details:"
	cat "$TESTOUT/regression.diffs"
	exit 1
fi
