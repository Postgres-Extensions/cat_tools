\set ECHO none
\i test/pgxntool/psql.sql
\t

/*
 * Sanity check: install a previous version and update to current.
 *
 * The 0.2.3→0.3.0 update script uses ALTER TYPE ... ADD VALUE, which cannot
 * run inside a transaction block or in an extension update script
 * (PROCESS_UTILITY_QUERY context) on PG11 and below. This restriction was
 * lifted in PG12. PG11 and below are therefore skipped entirely.
 */
SELECT current_setting('server_version_num')::int >= 120000 AS pg12plus \gset

\if :pg12plus
BEGIN;
CREATE EXTENSION cat_tools VERSION '0.2.2';

/*
 * Regression guard for the CONDITIONAL 0.2.2->0.2.3 view rebuild.
 *
 * A fresh 0.2.2 install has CORRECT catalog views, so the 0.2.2->0.2.3 update
 * must leave the public view chain (and anything depending on it) in place. The
 * old unconditional DROP+CREATE would abort here: these dependents are dropped
 * with no CASCADE by the rebuild, so ALTER EXTENSION UPDATE would error out
 * (failing this build test) if the rebuild ran on a fresh install. 0.2.3->0.3.0
 * does not touch these views, so a dependent survives the whole update chain.
 */
CREATE VIEW pg_temp.dep_on_pg_class_v AS SELECT * FROM cat_tools.pg_class_v;
CREATE VIEW pg_temp.dep_on_column AS SELECT * FROM cat_tools.column;

-- Suppress expected deprecation warnings from the update.
SET LOCAL client_min_messages = ERROR;
ALTER EXTENSION cat_tools UPDATE;

/*
 * Belt-and-suspenders: prove the dependents still exist and are queryable after
 * the update (a bare DO block emits no output, so build.out stays empty).
 */
DO $$
BEGIN
  PERFORM 1 FROM pg_temp.dep_on_pg_class_v;
  PERFORM 1 FROM pg_temp.dep_on_column;
END
$$;
ROLLBACK;
\else
/*
 * PG11 and below: skip the update test. ALTER TYPE ... ADD VALUE cannot run
 * inside a transaction block or in an extension update script on PG11 and
 * below (PROCESS_UTILITY_QUERY context). This restriction was lifted in PG12.
 */
\endif
