/*
 * Single, committed-once installer for the test suite's dependencies: the
 * cat_tools extension (see the modes below) and the test roles + grants.
 *
 * pgxntool's test/install feature runs this file COMMITTED, in its own
 * pg_regress session, BEFORE the main pgTAP suite. Because its state is
 * committed it persists into every test and runs ONCE instead of per-test
 * (pgTAP rolls back each test/sql/ file, so tests read these objects but never
 * modify them). Committing also mirrors a real production update: ALTER
 * EXTENSION UPDATE commits, then later transactions use the updated objects.
 * deps.sql (run per-test) installs nothing; it only sets the psql variables the
 * suite references.
 *
 * Three modes, selected by the cat_tools.test_load_mode placeholder GUC, which
 * the Makefile TEST_LOAD_SOURCE block sets via PGOPTIONS (fresh is the default):
 *   - fresh (default): plain CREATE EXTENSION cat_tools (current version).
 *   - update: CREATE EXTENSION at an older version (cat_tools.test_update_from,
 *     default 0.2.2) then ALTER EXTENSION UPDATE -- to cat_tools.test_update_to
 *     when that GUC is non-empty, otherwise to the current default_version.
 *     Reusing the SAME suite and expected output asserts an updated database
 *     behaves identically to a fresh install.
 *   - existing: the extension is ALREADY installed (by binary pg_upgrade, or an
 *     ALTER EXTENSION UPDATE performed outside the suite). load.sql must NOT
 *     drop/create/update it -- that would destroy exactly what the suite
 *     validates. It only asserts presence + current version, then creates the
 *     test roles.
 *
 * Version floor:
 *   - 0.2.2 is the default update-from floor: it is the OLDEST cat_tools
 *     version that installs cleanly on PG11+ (the 0.2.0/0.2.1 install scripts
 *     fail on PG11+/PG12+), so it is the WIDEST update path this harness can
 *     exercise across the supported PostgreSQL range -- not a claim that we
 *     only care about 0.2.2.
 */
SET client_min_messages = WARNING;

/*
 * The test-role names live in one place, test/roles.sql, \i'd here and mirrored
 * per-test by test/deps.sql (psql variables are session-local, so both this
 * committed installer and each rolled-back test file must set them). Each :var
 * holds the identifier; the pg_temp helper functions below receive it as a text
 * literal (:'use_role') and quote it via format(%I); the identifier-position
 * uses below (GRANT ... TO :"use_role") quote it directly. The names require
 * quoting, so an unquoted reference would surface as a test failure.
 */
\i test/roles.sql

/*
 * Mode selection. The Makefile always exports cat_tools.test_load_mode via
 * PGOPTIONS. Read it WITHOUT missing_ok: if the GUC did not propagate (a break
 * anywhere in make -> PGOPTIONS -> env -> psql), current_setting errors here and
 * the whole install step fails loudly, instead of silently falling back to a
 * default and running the wrong suite. The DO block then rejects any value
 * other than fresh/update/existing with a clear message.
 */
SELECT current_setting('cat_tools.test_load_mode') AS cat_tools_test_load_mode
\gset

DO $DO$
BEGIN
  IF current_setting('cat_tools.test_load_mode') NOT IN ('fresh', 'update', 'existing') THEN
    RAISE EXCEPTION
      'cat_tools.test_load_mode must be ''fresh'', ''update'' or ''existing'', got ''%'''
      , current_setting('cat_tools.test_load_mode')
    ;
  END IF;
END
$DO$;

SELECT
    :'cat_tools_test_load_mode' = 'update'   AS cat_tools_mode_update
  , :'cat_tools_test_load_mode' = 'existing' AS cat_tools_mode_existing
\gset

\if :cat_tools_mode_existing
/*
 * existing mode: do NOT touch the extension. Assert it is installed and at the
 * current default_version -- the pg_upgrade / external update the database just
 * went through is exactly what the suite is validating, so dropping or
 * reinstalling it would defeat the test. Fail loudly on absence or mismatch.
 * (CI additionally plants a dependency guard so a stray non-CASCADE drop would
 * error rather than silently reinstall; see bin/test_existing.)
 */
DO $DO$
DECLARE
  v_installed text := (SELECT extversion FROM pg_extension WHERE extname = 'cat_tools');
  v_default   text := (SELECT default_version FROM pg_available_extensions WHERE name = 'cat_tools');
BEGIN
  IF v_installed IS NULL THEN
    RAISE EXCEPTION 'test_load_mode=existing but the cat_tools extension is not installed';
  END IF;
  IF v_installed IS DISTINCT FROM v_default THEN
    RAISE EXCEPTION
      'cat_tools is installed at version % but the current default_version is %'
      , v_installed, v_default
    ;
  END IF;
END
$DO$;
\else
/*
 * fresh / update: (re)install from scratch. Drop-first so a re-run on a
 * persistent cluster installs the newest build instead of reusing stale
 * objects. Drop the extension, then the roles.
 *
 * DROP EXTENSION does not remove cat_tools__usage: the extension scripts create
 * it with CREATE ROLE, and roles are global objects, not extension members, so
 * they survive DROP EXTENSION. The 0.2.2 install script uses a bare CREATE ROLE
 * (unlike the current version's duplicate-tolerant DO block), so a leftover role
 * would break a re-run in update mode. Drop all three roles explicitly via
 * pg_temp.drop_role(): DROP OWNED BY first strips privileges granted TO the role
 * (e.g. CREATE on public, cat_tools__usage membership) so DROP ROLE cannot fail
 * with a dependency error; the pg_roles guard skips a not-yet-existing role
 * (DROP OWNED BY errors on one), and format(%I) quotes the name correctly.
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

\if :cat_tools_mode_update
/*
 * update mode: install an older version, then ALTER EXTENSION UPDATE. The
 * from/to versions come from the Makefile (TEST_UPDATE_FROM / TEST_UPDATE_TO,
 * exported as GUCs). An empty test_update_to means "update to the current
 * default_version" (the widest path); a non-empty value targets a specific
 * version (e.g. the explicit 0.2.1 -> 0.2.2 script).
 */
SELECT current_setting('cat_tools.test_update_from') AS cat_tools_test_update_from \gset
SELECT current_setting('cat_tools.test_update_to')   AS cat_tools_test_update_to   \gset
/*
 * Build the optional target clause once so a SINGLE ALTER EXTENSION covers both
 * cases: an empty test_update_to yields '' (update to the current
 * default_version -- the widest path); a non-empty value yields "TO '<v>'".
 * format(%L) quotes the version literal safely; the bare :clause interpolation
 * below then drops it in verbatim.
 */
SELECT CASE WHEN :'cat_tools_test_update_to' = '' THEN ''
            ELSE format('TO %L', :'cat_tools_test_update_to') END
  AS cat_tools_update_to_clause \gset

CREATE EXTENSION cat_tools VERSION :'cat_tools_test_update_from';
/*
 * Suppress the deprecation NOTICEs the update scripts emit, matching the
 * approach used by test/build/upgrade.sql.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION cat_tools UPDATE :cat_tools_update_to_clause;
SET client_min_messages = WARNING;
\else
CREATE EXTENSION cat_tools;
\endif
-- end \if :cat_tools_mode_update (fresh vs. update install branch)
\endif
-- end \if :cat_tools_mode_existing (existing mode skips the whole (re)install block)

/*
 * Roles and grants the test suite depends on. Formerly created per-test in
 * deps.sql; now committed here once. Created idempotently because the source
 * differs by mode: fresh/update dropped them just above, while a freshly
 * pg_upgraded database (existing mode) never had them (roles are global, and
 * only the extension -- not the test roles -- is created before the pg_upgrade).
 * GRANT is idempotent, so re-applying the grants is always safe.
 */
CREATE FUNCTION pg_temp.create_role(
  role_name text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    EXECUTE format('CREATE ROLE %I', role_name);
  END IF;
END
$$;

SELECT pg_temp.create_role(:'no_use_role');
SELECT pg_temp.create_role(:'use_role');

GRANT cat_tools__usage TO :"use_role";
/*
 * PG15+ removed CREATE on the public schema from PUBLIC; grant it explicitly
 * for tests that create shadow names in public to check catalog-lookup
 * correctness.
 */
GRANT CREATE ON SCHEMA public TO :"use_role";

-- vi: expandtab ts=2 sw=2
