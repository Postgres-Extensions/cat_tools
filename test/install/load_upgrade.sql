/*
 * Upgrade-mode extension loader (see the Makefile TEST_LOAD_SOURCE block).
 *
 * pgxntool's test/install feature runs this file COMMITTED, in its own
 * pg_regress session, BEFORE the main pgTAP suite. That committed install is
 * essential: the 0.2.2->0.3.0 update runs ALTER TYPE ... ADD VALUE on
 * cat_tools.relation_relkind / relation_type, and PostgreSQL forbids USING a
 * newly added enum value in the same transaction that added it. The suite uses
 * those new values, so the upgrade must be committed here -- doing it inside a
 * test's transaction (as test/deps.sql does for a fresh install) would fail
 * with 55P04 "unsafe use of new value".
 *
 * This mirrors how a real production upgrade works (ALTER EXTENSION UPDATE
 * commits, then the new values are used by later transactions), so the same
 * expected output must pass in both fresh and upgrade modes. Any diff in
 * upgrade mode is a genuine fresh-vs-upgrade divergence.
 *
 * This file only runs when the Makefile enables test/install (upgrade mode);
 * in fresh mode PGXNTOOL_ENABLE_TEST_INSTALL is forced off, so deps.sql does
 * the fresh CREATE EXTENSION per test as always.
 *
 * 0.2.2 is the oldest version that installs cleanly on PG12+; do not lower it.
 * ALTER TYPE ... ADD VALUE also cannot run inside a transaction block at all on
 * PG11 and below, so upgrade mode requires PG12+ (CI restricts it accordingly).
 *
 * NOTE: pgTAP wraps each file under test/sql/ in a transaction that is rolled
 * back, so the extension created here is the ONLY committed copy; tests read it
 * but never modify or drop it.
 */
SET client_min_messages = WARNING;

CREATE EXTENSION cat_tools VERSION '0.2.2';

/*
 * Suppress the deprecation NOTICEs the update scripts emit, matching the
 * approach used by test/build/upgrade.sql.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION cat_tools UPDATE;
SET client_min_messages = WARNING;

-- vi: expandtab ts=2 sw=2
