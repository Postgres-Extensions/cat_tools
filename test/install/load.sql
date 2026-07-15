/*
 * Single, committed-once installer for the test suite.
 *
 * pgxntool's test/install feature runs this file COMMITTED, in its own
 * pg_regress session, BEFORE the main pgTAP suite (via a generated schedule).
 * Because the state it creates is committed, it persists into every test in
 * the suite. pgTAP wraps each test/sql/ file in a transaction that is rolled
 * back, so the objects installed here are the ONLY committed copy: tests read
 * them (create temp tables, SET ROLE, etc., all rolled back) but never modify
 * or drop them. This runs ONCE instead of per-test, which is a real time saver
 * for extensions with many dependencies or large install scripts.
 *
 * This is the ONE place the suite's dependencies are installed:
 *   - the cat_tools extension (fresh or upgrade, see below)
 *   - the test roles and their grants
 * deps.sql (run per-test) no longer installs anything; it only sets the psql
 * variables the suite references.
 *
 * Two modes, selected by the cat_tools.test_load_mode placeholder GUC, which
 * the Makefile TEST_LOAD_SOURCE block sets via PGOPTIONS (fresh is the
 * default; TEST_LOAD_SOURCE=upgrade selects upgrade):
 *   - fresh (default): plain CREATE EXTENSION cat_tools (current version).
 *   - upgrade: CREATE EXTENSION at the oldest cleanly-installable version and
 *     ALTER EXTENSION UPDATE to the current version.
 *
 * Why the upgrade must be committed here (not done per-test in deps.sql): the
 * update to the current version runs ALTER TYPE ... ADD VALUE on
 * cat_tools.relation_relkind / relation_type, and PostgreSQL forbids USING a
 * newly added enum value in the same transaction that added it (SQLSTATE
 * 55P04, "unsafe use of new value"). The suite uses those values, so the
 * update must be committed before the suite runs -- which mirrors a real
 * production upgrade (ALTER EXTENSION UPDATE commits, then later transactions
 * use the new values). Reusing the SAME expected output in both modes asserts
 * that an upgraded database behaves identically to a fresh install; any diff
 * in upgrade mode is a genuine fresh-vs-upgrade divergence.
 *
 * Version floors:
 *   - 0.2.2 is the OLDEST cat_tools version that installs cleanly on the
 *     supported PostgreSQL range (PG12+); the 0.2.0/0.2.1 install scripts fail
 *     on PG11+/PG12+. It is a backward-compat floor for the WIDEST update path
 *     we can exercise -- not a claim that we only care about 0.2.2. The update
 *     always targets the CURRENT version (default_version), never a hardcoded
 *     one.
 *   - PG12 is the PostgreSQL floor: ALTER TYPE ... ADD VALUE cannot run inside
 *     a transaction block (or an extension update script) at all before PG12.
 *     CI restricts upgrade mode accordingly.
 */
SET client_min_messages = WARNING;

/*
 * The test-role names come from test/roles.sql (the single source of truth,
 * also loaded per-test by test/deps.sql). Each :var holds the RAW identifier;
 * we quote it at every use site (:"use_role" for CREATE ROLE / GRANT, :'use_role'
 * for the pg_temp.drop_role() text argument).
 */
\i test/roles.sql

/*
 * Mode selection. The Makefile always exports cat_tools.test_load_mode via
 * PGOPTIONS (fresh or upgrade). Read it WITHOUT missing_ok: if the GUC did not
 * propagate (a break anywhere in make -> PGOPTIONS -> env -> psql), current_setting
 * errors here and the whole install step fails loudly, instead of silently
 * falling back to fresh and running the wrong suite. The DO block then rejects
 * any value other than fresh/upgrade with a clear message.
 */
SELECT current_setting('cat_tools.test_load_mode') AS cat_tools_test_load_mode
\gset

DO $$
BEGIN
  IF current_setting('cat_tools.test_load_mode') NOT IN ('fresh', 'upgrade') THEN
    RAISE EXCEPTION
      'cat_tools.test_load_mode must be ''fresh'' or ''upgrade'', got ''%'''
      , current_setting('cat_tools.test_load_mode')
    ;
  END IF;
END
$$;

/*
 * Drop-first: a re-run on an existing cluster must install the newest build,
 * never reuse stale objects left by a previous run. Drop the extension, then
 * the roles.
 *
 * DROP EXTENSION does not remove cat_tools__usage: the extension scripts
 * create it with CREATE ROLE, and roles are global objects, not extension
 * members, so they survive DROP EXTENSION. The 0.2.2 install script uses a
 * bare CREATE ROLE (unlike the current version's duplicate-tolerant DO block),
 * so a leftover role would break a re-run in upgrade mode. Drop all three
 * roles explicitly via pg_temp.drop_role(): DROP OWNED BY first strips
 * privileges granted TO the role (e.g. CREATE on public, cat_tools__usage
 * membership) so DROP ROLE cannot fail with a dependency error; the pg_roles
 * guard skips a not-yet-existing role (DROP OWNED BY errors on one), and
 * format(%I) quotes the name correctly for the now mixed-case test roles.
 * cat_tools__usage is not a test role (the extension script creates it) but is
 * routed through the same helper so an upgrade-mode re-run starts clean.
 */
DROP EXTENSION IF EXISTS cat_tools CASCADE;

CREATE FUNCTION pg_temp.drop_role(
  role_name text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    EXECUTE format('DROP OWNED BY %I', role_name);
    EXECUTE format('DROP ROLE IF EXISTS %I', role_name);
  END IF;
END
$$;

SELECT pg_temp.drop_role(:'use_role');
SELECT pg_temp.drop_role(:'no_use_role');
SELECT pg_temp.drop_role('cat_tools__usage');

SELECT :'cat_tools_test_load_mode' = 'upgrade' AS cat_tools_upgrade_mode
\gset

\if :cat_tools_upgrade_mode
CREATE EXTENSION cat_tools VERSION '0.2.2';
/*
 * Suppress the deprecation NOTICEs the update scripts emit, matching the
 * approach used by test/build/upgrade.sql. ALTER EXTENSION UPDATE with no
 * target version updates to the current default_version.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION cat_tools UPDATE;
SET client_min_messages = WARNING;
\else
CREATE EXTENSION cat_tools;
\endif

/*
 * Test roles and grants the suite depends on. Formerly created per-test in
 * deps.sql; now committed here once. Names come from test/roles.sql; the
 * mixed-case identifiers must be double-quoted via :"var".
 */
CREATE ROLE :"no_use_role";
CREATE ROLE :"use_role";

GRANT cat_tools__usage TO :"use_role";
/*
 * PG15+ removed CREATE on the public schema from PUBLIC; grant it explicitly
 * for tests that create shadow names in public to check catalog-lookup
 * correctness.
 */
GRANT CREATE ON SCHEMA public TO :"use_role";

-- vi: expandtab ts=2 sw=2
