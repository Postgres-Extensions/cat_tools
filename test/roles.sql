/*
 * Single source of truth for the test role names (\i'd by test/install/load.sql
 * and, per-test, test/deps.sql). Names intentionally chosen to require quoting
 * (spaces, a colon, mixed case), so a missing :"var" / :'var' quote fails loudly
 * rather than passing silently.
 */
\set no_use_role 'cat_tools testing: NO USE'
\set use_role 'cat_tools testing: USE'
