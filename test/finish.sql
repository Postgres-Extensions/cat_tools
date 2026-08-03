/*
 * Asserts cat_tools' own schema(s) are absent from the resolved search_path --
 * checked here (file end, before finish()) rather than only at setup, so a
 * test that mutates search_path mid-file and never restores it is caught. Not
 * foolproof: mutate-then-restore before this line still slips through. \i'd by
 * every SQL file under test/sql; bump that file's plan() by one to account
 * for it.
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
