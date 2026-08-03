\set ECHO none

\i test/setup.sql

\set test_enum enum_range_srf_test_enum
-- test_role is set in test/deps.sql

SELECT plan(
  0
  + 1
  + 2 -- no_use tests
  + 1
  + 1 -- search_path still clean (test/finish.sql)
);

SELECT lives_ok(
  $$CREATE TYPE $$ || :'test_enum' || $$ AS ENUM( 'ZZZ Label 1', 'Label 2' )$$
  , 'Create test enum'
);

SET LOCAL ROLE :"no_use_role";
SELECT throws_ok(
  format( 'SELECT cat_tools.enum_range%s( %L )', suffix, :'test_enum' )
  , '42501'
  , NULL
  , 'Permission denied trying to run functions'
)
  FROM unnest( array['', '_srf'] ) AS suffix
;

SET LOCAL ROLE :"use_role";

-- This will test both functions
SELECT results_eq(
  format( 'SELECT cat_tools.enum_range_srf( %L )', :'test_enum' )
  , $$VALUES ( 'ZZZ Label 1' ), ( 'Label 2' )$$
);

\i test/finish.sql
\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
