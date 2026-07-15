-- IF NOT EXISTS will emit NOTICEs, which is annoying
SET client_min_messages = WARNING;

/*
 * The extension and the test roles are installed ONCE, COMMITTED, before the
 * suite by test/install/load.sql (pgxntool's test/install feature), instead of
 * per-test here. So this file no longer runs CREATE EXTENSION or CREATE ROLE:
 * all it does is set the psql variables the suite references (setup.sql and
 * the test/sql/ files). psql variables are session-local, not committed DB
 * state, so they must still be (re)set per test file.
 *
 * pgTAP is loaded by setup.sql. Add any per-test dependency \set/statements
 * here; committed dependencies belong in test/install/load.sql.
 */
\set no_use_role cat_tools_testing__no_use_role
\set use_role cat_tools_testing__use_role
