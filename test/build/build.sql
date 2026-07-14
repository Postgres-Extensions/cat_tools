\set ECHO none

\i test/pgxntool/psql.sql
\t

BEGIN;
CREATE SCHEMA cat_tools;

/*
 * The install script no longer sets client_min_messages itself (that is the
 * caller's job; deps.sql does the same for the main suite). Suppress NOTICEs
 * here so build.out does not capture verbose, version-specific messages (e.g.
 * "%TYPE converted to regclass" with a source-file LOCATION line).
 */
SET client_min_messages = WARNING;

\i sql/cat_tools.sql

\echo # TRANSACTION INTENTIONALLY LEFT OPEN!

-- vi: expandtab sw=2 ts=2
