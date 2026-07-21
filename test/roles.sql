/*
 * Single source of truth for the test role names. \i'd by test/install/load.sql
 * (which creates the roles, committed-once) and per-test by test/deps.sql (psql
 * variables are session-local, so each rolled-back test file must re-set them).
 * The names intentionally require quoting, so a quoting bug in the code under
 * test surfaces as a failure rather than passing silently on a quote-free name.
 */
\set no_use_role 'cat_tools testing: NO USE'
\set use_role 'cat_tools testing: USE'
