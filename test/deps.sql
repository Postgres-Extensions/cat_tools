-- IF NOT EXISTS will emit NOTICEs, which is annoying
SET client_min_messages = WARNING;

-- Add any test dependency statements here
-- Note: pgTap is loaded by setup.sql
--CREATE EXTENSION IF NOT EXISTS ...;

/*
 * Now load our extension.
 *
 * Fresh mode (default): create the current version directly, inside this
 * per-test transaction, exactly as always. We don't use IF NOT EXISTS because
 * we want an error if the extension is somehow already loaded (we want the
 * very latest version).
 *
 * Upgrade mode (`make test TEST_LOAD_SOURCE=upgrade`): the extension has
 * ALREADY been installed at the 0.2.2 floor and updated to the current version
 * by test/install/load_upgrade.sql, which runs COMMITTED before the suite. So
 * here we must NOT create it again -- we leave the already-present, upgraded
 * extension in place and run the identical suite against it.
 *
 * The upgrade must be committed (not done here inside the per-test
 * transaction) because the 0.2.2->0.3.0 update uses ALTER TYPE ... ADD VALUE
 * on cat_tools.relation_relkind / relation_type, and PostgreSQL forbids USING
 * a newly added enum value in the same transaction that added it. The suite's
 * relation__kind()/relation__relkind() calls use those new values, so an
 * in-transaction upgrade would fail with 55P04 "unsafe use of new value".
 * See test/install/load_upgrade.sql.
 *
 * The mode is signalled by the cat_tools.test_load_mode placeholder GUC, which
 * the Makefile TEST_LOAD_SOURCE block sets via PGOPTIONS.
 */
SELECT lower(coalesce(
      current_setting('cat_tools.test_load_mode', true), 'fresh'
    )) = 'upgrade' AS cat_tools_upgrade_mode
\gset
\if :cat_tools_upgrade_mode
/* Extension already installed + upgraded (committed) by test/install. */
\else
CREATE EXTENSION cat_tools;
\endif

-- Used by several unit tests
\set no_use_role cat_tools_testing__no_use_role
\set use_role cat_tools_testing__use_role
CREATE ROLE :no_use_role;
CREATE ROLE :use_role;

GRANT cat_tools__usage TO :use_role;
-- PG15+ removed CREATE on public schema from PUBLIC; grant it explicitly for tests
-- that need to create shadow names in public to test catalog lookup correctness.
GRANT CREATE ON SCHEMA public TO :use_role;

