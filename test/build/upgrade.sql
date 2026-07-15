\set ECHO none
\i test/pgxntool/psql.sql
\t

/*
 * Sanity check: install a previous version and update to current.
 *
 * The 0.2.2→0.3.0 update script uses ALTER TYPE ... ADD VALUE, which cannot
 * run inside a transaction block or in an extension update script
 * (PROCESS_UTILITY_QUERY context) on PG11 and below. This restriction was
 * lifted in PG12. PG11 and below are therefore skipped entirely.
 */
SELECT current_setting('server_version_num')::int >= 120000 AS pg12plus \gset

\if :pg12plus
BEGIN;
CREATE EXTENSION cat_tools VERSION '0.2.2';
-- Suppress expected deprecation warnings from the update.
SET LOCAL client_min_messages = ERROR;
ALTER EXTENSION cat_tools UPDATE;
ROLLBACK;
\else
/*
 * PG11 and below: skip the update test. ALTER TYPE ... ADD VALUE cannot run
 * inside a transaction block or in an extension update script on PG11 and
 * below (PROCESS_UTILITY_QUERY context). This restriction was lifted in PG12.
 */
\endif
