\set ECHO none

\i test/setup.sql

-- test_role is set in test/deps.sql

SET LOCAL ROLE :"use_role";

SELECT plan(
  0

  + 1 -- view count sanity

  + 2 -- pg_extension__get for good extension
  + 1 -- pg_extension__get for bad extension

  + 1 -- extension__schemas_unique
  + 1 -- extension__schemas
  + 1 -- extension__schemas_unique with bad schema
);

SELECT is(
  (SELECT count(*) FROM cat_tools.pg_extension_v)
  , (SELECT count(*) FROM pg_catalog.pg_extension)
  , 'cat_tools.pg_extension view row count'
);

SELECT isnt_empty(
  $$SELECT * FROM cat_tools.pg_extension__get('cat_tools')$$
  , 'Sanity-check that we get a row for our extension'
);
SELECT bag_eq(
  $$SELECT * FROM cat_tools.pg_extension__get('cat_tools')$$
  , format(
    $$SELECT %s, %s, extconfig::regclass[] AS ext_config_table
      FROM pg_extension e
        JOIN pg_namespace n ON n.oid = extnamespace
      WHERE extname = 'cat_tools'
    $$
    -- PG12+ includes oid in SELECT *; older versions need explicit e.oid
    , CASE WHEN pg_temp.major() >= 1200 THEN 'e.*' ELSE 'e.oid, e.*' END
    , CASE WHEN pg_temp.major() < 905 THEN 'nspname AS extschema'
      ELSE 'extnamespace::regnamespace AS extschema'
      END
  )
  , 'pg_extension__get() returns correct data'
);

SELECT throws_ok(
  $$SELECT * FROM cat_tools.pg_extension__get('absurd bogus extension name')$$
  , '42704'
  , 'extension "absurd bogus extension name" does not exist'
  , 'pg_extension__get() for non-existent extension throws an error'
);

-- Assume that if this works then the array version does as well
SELECT bag_eq(
  $$SELECT * FROM unnest(cat_tools.extension__schemas_unique('{cat_tools, plpgsql, cat_tools}')::text[])$$
  , $$SELECT nspname::text FROM pg_namespace n JOIN pg_extension e ON n.oid = extnamespace WHERE extname IN ('plpgsql', 'cat_tools')$$
  , 'Verify extension__schemas_unique(text) returns correct data'
);

SELECT results_eq(
  $$SELECT * FROM unnest(cat_tools.extension__schemas('{cat_tools, cat_tools}')::text[])$$
  , array[ 'cat_tools'::text, 'cat_tools' ]
  , 'Verify extension__schemas(text) returns correct data'
);

SELECT throws_ok(
  $$SELECT * FROM unnest(cat_tools.extension__schemas_unique('cat_tools, plpgsql,"absurd bogus extension name"'))$$
  , '42704'
  , 'extension "absurd bogus extension name" does not exist'
  , 'extension__schemas_unique with bogus extension fails'
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
