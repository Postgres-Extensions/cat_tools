\set ECHO none

\i test/setup.sql

-- test_role is set in test/deps.sql

SET LOCAL ROLE :"use_role";

CREATE FUNCTION pg_temp.extra_types()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
SELECT '{}'::text[]
  || CASE WHEN pg_temp.major() < 905 THEN '{policy,transform}'::text[] END
  || CASE WHEN pg_temp.major() < 903 THEN '{event trigger}'::text[] END
$$;

CREATE TEMP VIEW obj_type AS
  SELECT object_type::text COLLATE "C", true AS is_real
    FROM cat_tools.enum_range_srf('cat_tools.object_type') r(object_type)
  UNION ALL -- INTENTIONALLY UNION ALL! We want dupes if something gets hosed
  SELECT u COLLATE "C", false
    FROM unnest(pg_temp.extra_types()) u
  ORDER BY 1 -- Intentionally done by ordinal
;

CREATE FUNCTION pg_temp.throws_other(
  cmd text
  , errcode text
  , description text
) RETURNS text LANGUAGE plpgsql AS $body$
BEGIN
  EXECUTE cmd;
  RETURN ok(false, description) || E'\n'
    || diag('      caught: no exception')
  ;
EXCEPTION WHEN others THEN
  IF errcode = SQLSTATE THEN
    RETURN ok( FALSE, description ) || E'\n' || diag(
           '      caught: ' || SQLSTATE || ': ' || SQLERRM ||
        E'\n      wanted: any other error' )
    ;
  ELSE
    RETURN ok( TRUE, description );
  END IF;
END
$body$;

SELECT plan(
  0
  + 2 -- extra_types sanity
  + 4 -- no_use tests
  + 1 -- definition
  + 3 * (SELECT count(*)::int FROM obj_type)

  + (SELECT count(*)::int FROM obj_type) -- object__is_address_unsupported()

  + 3 -- object__regtype_catalog

  -- Catalog search path
  + 1
  + 3 * 2

  + 1 -- objects__shared
);

SELECT is(
  array_upper(pg_temp.extra_types(),1)
  , CASE -- REMEMBER: first match wins, so must be ascending!
    WHEN pg_temp.major() < 903 THEN 3
    WHEN pg_temp.major() < 905 THEN 2
  END
  , 'sanity check size of pg_temp.extra_types()'
);
SELECT is(
  (SELECT count(*)::int FROM obj_type)
  , 53
  , 'sanity check size of pg_temp.obj_type'
);

SET LOCAL ROLE :"no_use_role";
SELECT throws_ok(
  format( 'SELECT NULL::%I', typename )
  , '42704' -- undefined_object; not exactly correct, but close enough
  , NULL
  , 'Permission denied trying to use types'
)
  FROM (VALUES
    ('cat_tools.constraint_type')
    , ('cat_tools.procedure_type')
    , ('cat_tools.object_type')
  ) v(typename)
;
SELECT throws_ok(
  format( 'SELECT cat_tools.object__catalog( NULL::%I )', argtype )
  , '42501' -- insufficient_privilege
  , NULL
  , 'Permission denied trying to run functions'
)
  FROM (VALUES
    ('text'::regtype)
  ) v(argtype)
;

SET LOCAL ROLE :"use_role";

SELECT function_returns(
  'cat_tools'
  , 'object__catalog'
  , array[ 'cat_tools.object_type'::name ]
  , 'regclass'::name
);

-- object__regtype_catalog
SELECT throws_ok(
  $$SELECT cat_tools.object__reg_type_catalog('int'::regtype)$$
  , '42809'
  , 'integer is not a object identifier type'
  , $$Invalid object identifier type throws correct error$$
);
CREATE TYPE pg_temp.regtest AS RANGE(subtype = int);
SELECT throws_ok(
  $$SELECT cat_tools.object__reg_type_catalog('pg_temp.regtest'::regtype)$$
  , '0A000'
  , 'object identifier type regtest is not supported'
  , $$Invalid pseudotype throws correct error$$
);

SELECT is(
  cat_tools.object__reg_type_catalog('regclass'::regtype)
  , 'pg_class'::regclass
  , $$Sanity-check cat_tools.object__reg_type_catalog('regclass'::regtype)$$
); -- TODO: all reg*


/*
 * Verify all object types are either marked as not addressable or don't throw
 * that error in pg_get_object_address().
 */
SELECT CASE
  WHEN pg_temp.major() < 905 THEN
    pass(
      format( 'check addressability for object type %L', object_type )
    )
  WHEN cat_tools.object__is_address_unsupported(object_type) THEN
    throws_ok(
       format(
        $$SELECT pg_get_object_address(%L,array[''],array[''])$$
        , object_type
      )
      , '22023'
      , format( 'unsupported object type "%s"', object_type )
      , format( 'check addressability for object type %L', object_type )
    )
  ELSE
    pg_temp.throws_other(
       format(
        $$pg_get_object_address(%L,array[''],array[''])$$
        , object_type
      )
      , '22023'
      , format( 'check addressability for object type %L', object_type )
    )
  END
  FROM obj_type
;

/*
 * It doesn't seem worth it to hand-check all of these. Just make sure we get a valid relation for all of them.
 *
 * NOTE: Since object__catalog returns regclass we know anything it returns must at least be a valid relation.
 * Should probably at least verify that whatever is returned lives in pg_catalog...
 */
SELECT lives_ok(
      CASE WHEN is_real THEN format( $$SELECT * FROM cat_tools.object__catalog(%L)$$, object_type )
      ELSE 'SELECT 1'
      END
      , format( $$lives_ok: SELECT * FROM cat_tools.object__catalog(%L)$$, object_type )
    )
  FROM obj_type
;

SELECT lives_ok(
      CASE WHEN is_real THEN format( $$SELECT * FROM cat_tools.object__reg_type(%L)$$, object_type )
      ELSE 'SELECT 1'
      END
      , format( $$lives_ok: SELECT * FROM cat_tools.object__reg_type(%L)$$, object_type )
    )
  FROM obj_type
;


-- Verify object__address_classid
SELECT CASE WHEN is_real THEN
    is(
      cat_tools.object__address_classid(object_type)
      , CASE
          WHEN object_type::text LIKE '% column' THEN 'pg_class'::regclass
          ELSE cat_tools.object__catalog(object_type)
        END
      , format( 'Verify cat_tools.object__address_classid(%L)', object_type )
    )
  ELSE
    pass(
      format( 'Verify cat_tools.object__address_classid(%L)', object_type )
    )
  END
  FROM obj_type
;

-- Verify catalog correctness
SELECT lives_ok(
  $$SET search_path = public,tap,pg_catalog$$ -- Note that we must explicitly set pg_catalog at the end of the path
  , 'Change search_path'
);

SELECT lives_ok(
  'CREATE TABLE pg_class()'
  , 'Create bogus pg_class table'
);
SELECT lives_ok(
  'CREATE TYPE regclass AS ENUM()'
  , 'Create bogus regclass type'
);
SELECT isnt(
  'pg_class'::pg_catalog.regclass
  , 'pg_catalog.pg_class'::pg_catalog.regclass
  , $$Simple 'pg_class'::pg_catalog.regclass should not return pg_catalog.pg_class$$
);
SELECT isnt(
  'regclass'::regtype
  , 'pg_catalog.regclass'::regtype
  , $$Simple 'regclass'::regtype should not return pg_catalog.regtype$$
);
SELECT is(
  cat_tools.object__catalog('table')
  , 'pg_catalog.pg_class'::pg_catalog.regclass
  , $$cat_tools.object__catalog('table') returns pg_catalog.pg_class$$
);
SELECT is(
  cat_tools.object__reg_type('table')
  , 'pg_catalog.regclass'::regtype
  , $$cat_tools.object__catalog('table') returns pg_catalog.pg_class$$
);

SELECT bag_eq(
  $$SELECT * FROM cat_tools.objects__shared_srf()$$
  , array(
    SELECT type::cat_tools.object_type FROM
      -- types and their catalogs
      (SELECT *, cat_tools.object__catalog(type) FROM cat_tools.enum_range_srf('cat_tools.object_type') type) a
      JOIN pg_catalog.pg_class c ON c.oid = a.object__catalog
      WHERE NOT EXISTS(
          -- Does the table have a column with relid or namespace in the column name?
          SELECT 1
            FROM information_schema.columns
            WHERE table_schema='pg_catalog'
              AND table_name = a.object__catalog::text
              AND column_name ~ 'relid|namespace'
        )
        AND c.reltablespace=(SELECT oid FROM pg_tablespace WHERE spcname = 'pg_global')
  )
  , 'Verify objects__shared_src() returns correct values'
);

\i test/pgxntool/finish.sql

--select name,setting from pg_settings where name ~ '^lc_';

-- vi: expandtab ts=2 sw=2
