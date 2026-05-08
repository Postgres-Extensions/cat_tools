\set ECHO none

\i test/setup.sql

\set s cat_tools

SET LOCAL ROLE :use_role;

/*
 * The two enums should be the same size; we use greatest() to iterate over
 * both so that if they ever diverge we will get a NULL failure rather than
 * silently missing entries.
 */
CREATE TEMP VIEW kinds AS
  SELECT
      (cat_tools.enum_range('cat_tools.relation_type'))[gs]    AS kind
      , (cat_tools.enum_range('cat_tools.relation_relkind'))[gs] AS relkind
    FROM generate_series(
      1
      , greatest(
        array_upper(cat_tools.enum_range('cat_tools.relation_type'), 1)
        , array_upper(cat_tools.enum_range('cat_tools.relation_relkind'), 1)
      )
    ) gs
;

SELECT plan(
  (1 + 2 + 2 * (SELECT count(*)::int FROM kinds)) -- relation_type enum mapping
  + 5 -- relation__is_temp
  + 5 -- relation__is_catalog
  + 8 -- relation__column_names
);

-- relation_type enum mapping
SELECT is(
  (SELECT count(*)::int FROM kinds)
  , 10
  , 'Verify count from kinds'
);

SELECT is(
  cat_tools.relation__kind('r')
  , 'table'
  , 'Simple sanity check of relation__kind()'
);
SELECT is(
  cat_tools.relation__relkind('table')
  , 'r'
  , 'Simple sanity check of relation__relkind()'
);

SELECT is(cat_tools.relation__relkind(kind)::text, relkind, format('SELECT cat_tools.relation_relkind(%L)', kind))
  FROM kinds
;

SELECT is(cat_tools.relation__kind(relkind)::text, kind, format('SELECT cat_tools.relation_type(%L)', relkind))
  FROM kinds
;

-- relation__is_temp
\set f relation__is_temp

SET LOCAL ROLE :no_use_role;

SELECT throws_ok(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , 'pg_catalog.pg_class'
  )
  , '42501'
  , NULL
  , 'Verify public has no perms'
);

SET LOCAL ROLE :use_role;

SELECT is(
  cat_tools.relation__is_temp('pg_catalog.pg_class'::regclass)
  , false
  , 'pg_catalog.pg_class is not a temp relation'
);

SELECT lives_ok($$CREATE TEMP TABLE is_temp_test()$$, 'Create temp table for testing');

SELECT is(
  cat_tools.relation__is_temp('is_temp_test'::regclass)
  , true
  , 'temp relation is correctly identified as temp'
);

SELECT is(
  cat_tools.relation__is_temp(NULL)
  , NULL
  , 'NULL input returns NULL (STRICT function)'
);

-- relation__is_catalog
\set f relation__is_catalog

SET LOCAL ROLE :no_use_role;

SELECT throws_ok(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , 'pg_catalog.pg_class'
  )
  , '42501'
  , NULL
  , 'Verify public has no perms'
);

SET LOCAL ROLE :use_role;

SELECT is(
  cat_tools.relation__is_catalog('pg_catalog.pg_class'::regclass)
  , true
  , 'pg_catalog.pg_class is in pg_catalog schema'
);

SELECT lives_ok($$CREATE TEMP TABLE is_catalog_test()$$, 'Create temp table for testing');

SELECT is(
  cat_tools.relation__is_catalog('is_catalog_test'::regclass)
  , false
  , 'temp relation is not in pg_catalog schema'
);

SELECT is(
  cat_tools.relation__is_catalog(NULL)
  , NULL
  , 'NULL input returns NULL (STRICT function)'
);

-- relation__column_names
\set f relation__column_names

SET LOCAL ROLE :no_use_role;

SELECT throws_ok(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , 'temp_test_table'
  )
  , '42501'
  , NULL
  , 'Verify public has no perms'
);

SET LOCAL ROLE :use_role;

SELECT lives_ok($$CREATE TEMP TABLE temp_test_table(col1 int, col2 text, col3 boolean, col4 timestamp, col5 numeric)$$, 'Create temp table with multiple columns');

SELECT is(
  cat_tools.relation__column_names('temp_test_table'::regclass)
  , '{col1,col2,col3,col4,col5}'::text[]
  , 'Temp table returns expected column names'
);

SELECT lives_ok($$ALTER TABLE temp_test_table DROP COLUMN col3$$, 'Drop middle column from temp table');

SELECT is(
  cat_tools.relation__column_names('temp_test_table'::regclass)
  , '{col1,col2,col4,col5}'::text[]
  , 'Temp table with dropped column returns expected column names'
);

SELECT lives_ok($$CREATE TEMP TABLE test_table(id int, name text)$$, 'Create test table with columns');

SELECT is(
  cat_tools.relation__column_names('test_table'::regclass)
  , '{id,name}'::text[]
  , 'Test table returns expected column names'
);

SELECT is(
  cat_tools.relation__column_names(NULL)
  , NULL
  , 'NULL input returns NULL (STRICT function)'
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
