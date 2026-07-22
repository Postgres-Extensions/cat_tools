/*
 * Single source of truth for the test role names (\i'd by test/install/load.sql
 * and, per-test, test/deps.sql). The names intentionally require quoting, so a
 * quoting bug in the code under test surfaces as a failure rather than passing
 * silently.
 */
\set no_use_role 'cat_tools testing: NO USE'
\set use_role 'cat_tools testing: USE'
