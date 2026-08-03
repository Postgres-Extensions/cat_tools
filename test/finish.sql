/*
 * Real, counted pgTAP test (not a silent DO block, unlike the check this
 * replaces) that cat_tools' own schemas are still absent from the resolved
 * search_path at the END of this file -- not just at the start. \i'd by every
 * SQL file under test/sql right before finish(), so a future test file
 * forgetting to bump its own plan() count for it is caught immediately, a
 * natural nudge not to add a search_path-dependent test without thinking
 * about it.
 *
 * Confirmed empirically: each SQL file under test/sql runs as its own psql
 * connection, wrapped in a transaction that is never committed (see
 * test/pgxntool/finish.sql's "TRANSACTION INTENTIONALLY LEFT OPEN") and so
 * always rolls back when that connection closes; a plain SET search_path
 * made anywhere in the file is undone by that rollback, so it can never leak
 * into a LATER file no matter when we check. What a start-only check (as
 * test/setup.sql's used to be) cannot see is a mutation that remains in
 * effect for the rest of THIS SAME file's own tests after it happens --
 * checking again here, immediately before that rollback, catches that case.
 * Not foolproof: a test that mutates search_path and then restores it before
 * this check runs would still slip through.
 */
SELECT ok(
    NOT ( 'cat_tools' = ANY (current_schemas(false)) OR '_cat_tools' = ANY (current_schemas(false)) )
  , format(
      'cat_tools schema(s) must not be part of the resolved search_path -- got %s'
      , current_schemas(false)
    )
);

-- Chain through to pgxntool's own finish, same wrapping pattern as test/setup.sql
-- does for test/pgxntool/setup.sql.
\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
