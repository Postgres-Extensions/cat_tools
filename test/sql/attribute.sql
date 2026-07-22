\set ECHO none

\i test/setup.sql

\set s cat_tools
CREATE TEMP VIEW func_calls AS
  SELECT * FROM (VALUES
    ('pg_attribute__get'::name, $$'pg_class', 'relname'$$::text)
  ) v(fname, args)
;
GRANT SELECT ON func_calls TO public;

SELECT plan(
  0
  -- Perms
  + (SELECT count(*)::int FROM func_calls)

  + 4 -- pg_attribute__get()
);

SET LOCAL ROLE :"no_use_role";

SELECT throws_ok(
      format(
        $$SELECT %I.%I( %s )$$
        , :'s', fname
        , args
      )
      , '42501'
      , NULL
      , 'Verify public has no perms'
    )
  FROM func_calls
;

SET LOCAL ROLE :"use_role";

/*
 * pg_attribute__get()
 */

/*
 * pg_attribute.attmissingval (PG11+) is anyarray pseudo-type, which has no equality
 * operator. Build a column list that replaces it with attmissingval::text[] so the
 * comparison works on all PG versions. On PG < 11 the column doesn't exist and is
 * simply absent from the list.
 */
CREATE FUNCTION pg_temp.attr_test_cols() RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(
      CASE WHEN attname = 'attmissingval' THEN 'attmissingval::text::text[]'
           ELSE attname::text
      END
      , ', ' ORDER BY attnum)
    FROM pg_attribute
    WHERE attrelid = 'pg_catalog.pg_attribute'::regclass
      AND attnum > 0
      AND NOT attisdropped
$$;

\set call 'SELECT * FROM %I.%I( %L, %L )'
\set n pg_attribute__get
SELECT throws_ok(
  format(
    :'call', :'s', :'n'
    , 'pg_catalog.foobar'
    , 'foobar'
  )
  , '42P01'
  , NULL
  , 'Non-existent relation throws error'
);
SELECT throws_ok(
  format(
    :'call', :'s', :'n'
    , 'pg_catalog.pg_class'
    , 'foobar'
  )
  , '42703'
  , 'column "foobar" of relation "pg_class" does not exist'
  , 'Non-existent column throws error'
);

SELECT results_eq(
  format(
    $$SELECT %s FROM %I.%I(%L, %L)$$
    , pg_temp.attr_test_cols()
    , :'s', :'n'
    , 'pg_catalog.pg_class'
    , 'relname'
  )
  , format(
    $$SELECT %s FROM pg_attribute WHERE attrelid = 'pg_class'::regclass AND attname='relname'$$
    , pg_temp.attr_test_cols()
  )
  , 'Verify details of pg_class.relname'
);
SELECT results_eq(
  format(
    $$SELECT %s FROM %I.%I(%L, %L)$$
    , pg_temp.attr_test_cols()
    , :'s', :'n'
    , 'pg_catalog.pg_tables'
    , 'tablename'
  )
  , format(
    $$SELECT %s FROM pg_attribute WHERE attrelid = 'pg_tables'::regclass AND attname='tablename'$$
    , pg_temp.attr_test_cols()
  )
  , 'Verify details of pg_tables.tablename'
);


\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
