-- IF NOT EXISTS will emit NOTICEs, which is annoying
SET client_min_messages = WARNING;

/*
 * The extension and the test roles are installed ONCE, COMMITTED, before the
 * suite by test/install/load.sql (pgxntool's test/install feature), instead of
 * per-test here. So this file no longer runs CREATE EXTENSION or CREATE ROLE:
 * all it does is (re)set the psql variables the suite references (setup.sql and
 * the test/sql/ files). psql variables are session-local, not committed DB
 * state, so they must still be (re)set per test file.
 *
 * The role names live in exactly one place, test/roles.sql, \i'd here and by
 * test/install/load.sql (which creates the roles). Add any OTHER per-test
 * dependency \set/statements here; committed dependencies belong in
 * test/install/load.sql.
 */
\i test/roles.sql
