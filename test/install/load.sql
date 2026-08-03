/*
 * Single, committed-once installer for the test suite's dependencies: the
 * cat_tools extension (see the modes below) and the test roles + grants.
 *
 * pgxntool's test/install feature runs this file COMMITTED, in its own
 * pg_regress session, BEFORE the main pgTAP suite. Because its state is
 * committed it persists into every test and runs ONCE instead of per-test
 * (pgTAP rolls back each test/sql/ file, so tests read these objects but never
 * modify them). Committing also MATTERS for correctness in update mode: the
 * update to the current version runs ALTER TYPE ... ADD VALUE on
 * cat_tools.relation_relkind / relation_type, and PostgreSQL forbids USING a
 * newly added enum value in the same transaction that added it (SQLSTATE 55P04,
 * "unsafe use of new value"). The suite uses those values, so the update must be
 * committed before the suite runs -- mirroring a real production update (ALTER
 * EXTENSION UPDATE commits, then later transactions use the new values).
 * deps.sql (run per-test) installs nothing; it only sets the psql variables the
 * suite references.
 *
 * ON_ERROR_STOP is REQUIRED here: pg_regress treats a nonzero psql exit code as
 * a real test failure (see the check-relkind-source comment in the `test` CI
 * job for a concrete example of this mechanism firing), but psql only exits
 * nonzero for a mid-script error when ON_ERROR_STOP is set -- without it, psql
 * prints the error and CONTINUES to the next statement, and this file's own
 * pg_regress entry self-compares (see test/install/.gitignore), so nothing
 * would ever diff either. Without ON_ERROR_STOP, EVERY RAISE EXCEPTION /
 * hard-error check in this file (the TEST_SCHEMA guard below, the
 * test_load_mode validation, the existing-mode version assertion) would print
 * a message and then silently let the rest of the file run to a "successful"
 * exit.
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
 * Version floors:
 *   - 0.2.2 is the OLDEST cat_tools version that installs cleanly on the
 *     supported PostgreSQL range (PG12+); the 0.2.0/0.2.1 install scripts fail
 *     on PG11+/PG12+. It is the default update-from floor -- the WIDEST update
 *     path we can exercise here -- not a claim that we only care about 0.2.2.
 *   - PG12 is the PostgreSQL floor: ALTER TYPE ... ADD VALUE cannot run inside
 *     a transaction block (or an extension update script) at all before PG12.
 */
/*
 * REQUIRED -- see the file header above for why. Without this, every RAISE
 * EXCEPTION guard below (TEST_SCHEMA, test_load_mode, the existing-mode
 * version assertion -- which already caught a real pg_tle regression once
 * this was added) prints an error and keeps going instead of aborting, and
 * this file's self-comparing pg_regress entry never diffs either -- so
 * removing this silently turns every one of those guards into a no-op.
 */
\set ON_ERROR_STOP on

SET client_min_messages = WARNING;

/*
 * The test-role names come from test/roles.sql (the single source of truth,
 * also loaded per-test by test/deps.sql). Each :var holds the RAW identifier;
 * we quote it at every use site (:"use_role" for CREATE ROLE / GRANT, :'use_role'
 * for the pg_temp helper text arguments).
 */
\i test/roles.sql

/*
 * TEST_SCHEMA targeting, independent of the mode selection below. The
 * Makefile always exports cat_tools.test_schema via PGOPTIONS (empty by
 * default); read it WITHOUT missing_ok, same reasoning as test_load_mode.
 *
 * THE POINT of this whole mechanism: prove cat_tools works correctly even
 * when the 'cat_tools' schema itself is NEVER part of the active
 * search_path. Installing WITH SCHEMA cat_tools always places the
 * extension's objects there (cat_tools' control file pins schema =
 * 'cat_tools' with relocatable = false), but that says nothing about
 * whether cat_tools' OWN internal SQL -- views and functions referencing
 * each other -- actually resolves those references without depending on
 * 'cat_tools' being searchable. Deliberately keeping a tooling extension's
 * schema off every role's default search_path (so it never shadows
 * anything, and callers must always schema-qualify it) is a normal,
 * legitimate deployment choice -- if cat_tools' own SQL secretly relied on
 * unqualified name resolution somewhere, it would keep working by accident
 * in this suite's ordinary fresh-install runs (which never touch
 * search_path at all) and only break in that realistic deployment. TEST_SCHEMA
 * exists to force that scenario and catch it here instead.
 *
 * Empty (the default): do nothing -- no CREATE SCHEMA, no SET search_path,
 * no WITH SCHEMA clause on CREATE EXTENSION below. This is the "brand-new
 * user just types CREATE EXTENSION cat_tools" path, landing wherever the
 * session's ambient search_path already resolves (which, per the control
 * file, is always 'cat_tools' regardless).
 *
 * Non-empty: create THAT schema (quoting it, so a name that requires
 * quoting -- e.g. mixed case -- works) and SET search_path to ONLY that
 * schema -- simulating a normal user's own working schema, unrelated to
 * cat_tools, with nothing else (no public, no "$user") ambient either.
 * CREATE EXTENSION below then explicitly adds WITH SCHEMA cat_tools --
 * deliberate, not implicit -- and after install (past the mode-selection
 * block below) a check asserts 'cat_tools' never appears in the resolved
 * search_path. The DO block immediately below is a much narrower sanity
 * check: only that THIS fixture's own SET search_path actually took effect,
 * not a test of cat_tools' behavior at all.
 */
SELECT current_setting('cat_tools.test_schema') AS cat_tools_test_schema \gset
SELECT :'cat_tools_test_schema' <> '' AS cat_tools_has_schema \gset

/*
 * \set (not a SQL CASE expression): cat_tools_has_schema holds Postgres's
 * boolean EXTERNAL TEXT form ('t'/'f') from the \gset above, which \if
 * accepts directly but which is NOT valid bare SQL (CASE WHEN t THEN ...
 * would parse "t" as an undefined column reference, not a boolean literal).
 */
\if :cat_tools_has_schema
\set cat_tools_with_schema_clause 'WITH SCHEMA cat_tools'
\else
\set cat_tools_with_schema_clause ''
\endif
-- end \if :cat_tools_has_schema (with_schema_clause \set)

\if :cat_tools_has_schema
CREATE SCHEMA IF NOT EXISTS :"cat_tools_test_schema";
SET search_path = :"cat_tools_test_schema";

/*
 * Sanity check on the fixture itself (see the comment above) -- not a test
 * of cat_tools.
 */
DO $DO$
BEGIN
  IF current_setting('cat_tools.test_schema') <> ALL (current_schemas(false)) THEN
    RAISE EXCEPTION
      'TEST_SCHEMA fixture schema % did not take effect in the resolved search_path'
      , current_setting('cat_tools.test_schema')
    ;
  END IF;
END
$DO$;
\endif
-- end \if :cat_tools_has_schema

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
 * CURRENT version -- the pg_upgrade / external update the database just went
 * through is exactly what the suite is validating, so dropping or
 * reinstalling it would defeat the test. Fail loudly on absence or mismatch.
 * (CI additionally plants a dependency guard so a stray non-CASCADE drop would
 * error rather than silently reinstall; see bin/test_existing.)
 *
 * The current version comes from the cat_tools.pgxn_version GUC (set by the
 * Makefile from PGXNVERSION), NOT pg_available_extensions.default_version:
 * that view is FILESYSTEM-based (it reads installed .control files) and
 * returns NULL for an extension registered purely via pg_tle, which is
 * exactly how the pg_tle CI jobs deploy cat_tools (no control file ever
 * touches disk there) -- confirmed by reproducing this existing-mode check
 * against a pg_tle-only registration locally, where the pg_available_extensions
 * version came back NULL and this assertion failed loudly (as it should
 * whenever it can't determine the current version, rather than silently
 * comparing against NULL). Mirrors bin/test_existing's own current_version()
 * helper, which avoids pg_available_extensions for the identical reason (it
 * shells out to `make -s print-PGXNVERSION` instead).
 */
DO $DO$
DECLARE
  v_installed text := (SELECT extversion FROM pg_extension WHERE extname = 'cat_tools');
  v_current   text := current_setting('cat_tools.pgxn_version');
BEGIN
  IF v_installed IS NULL THEN
    RAISE EXCEPTION 'test_load_mode=existing but the cat_tools extension is not installed';
  END IF;
  IF v_installed IS DISTINCT FROM v_current THEN
    RAISE EXCEPTION
      'cat_tools is installed at version % but the current version is %'
      , v_installed, v_current
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
 * (DROP OWNED BY errors on one), and format(%I) quotes the name correctly for
 * the test roles (which contain spaces and mixed case, so they must be quoted).
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

\if :cat_tools_has_schema
/*
 * Unlike a bare CREATE EXTENSION cat_tools (which auto-creates the schema
 * named in the control file if needed), CREATE EXTENSION ... WITH SCHEMA
 * cat_tools requires that schema to ALREADY exist -- even though it's the
 * exact same name the control file pins -- confirmed by testing this: it
 * errors "schema \"cat_tools\" does not exist" otherwise. DROP EXTENSION
 * above never drops the schema itself (only the extension's member
 * objects), so IF NOT EXISTS makes this correct whether this is the first
 * install or a re-run against a persistent cluster.
 */
CREATE SCHEMA IF NOT EXISTS cat_tools;
\endif
-- end \if :cat_tools_has_schema

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

CREATE EXTENSION cat_tools :cat_tools_with_schema_clause VERSION :'cat_tools_test_update_from';
/*
 * Suppress the deprecation NOTICEs the update scripts emit, matching the
 * approach used by test/build/upgrade.sql.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION cat_tools UPDATE :cat_tools_update_to_clause;
SET client_min_messages = WARNING;
\else
CREATE EXTENSION cat_tools :cat_tools_with_schema_clause;
\endif
-- end \if :cat_tools_mode_update (fresh vs. update install branch)

\if :cat_tools_has_schema
/*
 * THIS is the actual point of TEST_SCHEMA (see the comment where it's read,
 * above): cat_tools just installed WITH SCHEMA cat_tools while search_path
 * held only an unrelated schema -- if 'cat_tools' shows up in the resolved
 * search_path anyway, something (this fixture, a role default, a prior
 * statement) put it there, and cat_tools' own SQL cannot have been relying
 * on it being searchable to get this far. If cat_tools' internal views/
 * functions instead depend on unqualified name resolution somewhere, THAT
 * would surface as a later pgTAP failure, not here -- this check only
 * proves the precondition (cat_tools' schema absent from search_path) held
 * during install, which is what makes any later pgTAP pass actually mean
 * something.
 */
DO $DO$
BEGIN
  IF 'cat_tools' = ANY (current_schemas(false)) THEN
    RAISE EXCEPTION
      'cat_tools schema must NOT be part of the resolved search_path here -- got %'
      , current_schemas(false)
    ;
  END IF;
END
$DO$;
\endif
-- end \if :cat_tools_has_schema
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
