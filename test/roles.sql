/*
 * Single source of truth for the test role names.
 *
 * The suite refers to two roles through psql variables. Each variable holds the
 * RAW (unquoted) identifier; every use site is responsible for quoting it:
 *   - :"use_role"  -> a quoted SQL identifier (SET ROLE, GRANT ... TO, ...)
 *   - :'use_role'  -> the name as a string LITERAL (has_*_privilege(), etc.)
 *   - %I / quote_ident() in dynamic SQL
 *
 * The names deliberately contain spaces, a colon, and mixed case so they REQUIRE
 * double-quoting: any site that interpolates the bare identifier (:use_role)
 * would break the token apart / fold it to lower case and fail with
 * "role ... does not exist", surfacing a missing-quote bug instead of silently
 * passing.
 *
 * Both test/install/load.sql (which creates and drops the roles, committed once
 * before the suite) and test/deps.sql (per test, because psql variables are
 * session-local) \i this file so the names live in exactly one place.
 */
\set no_use_role 'cat_tools testing: NO USE'
\set use_role 'cat_tools testing: USE'
