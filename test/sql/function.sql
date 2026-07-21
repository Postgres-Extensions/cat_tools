\set ECHO none

\i test/setup.sql

\set s cat_tools
CREATE TEMP VIEW func_calls AS
  SELECT * FROM (VALUES
    ('function__arg_types'::name, $$'x'$$::text)
    , ('regprocedure'::name, $$'x', 'x'$$)
  ) v(fname, args)
;
GRANT SELECT ON func_calls TO public;

SELECT plan(
  0
  + (SELECT count(*)::int FROM func_calls)

  + 4 -- function__arg_types()

  + 2 -- regprocedure()
);

SET LOCAL ROLE :"no_use_role";

SELECT throws_ok(
      format(
        $$SELECT %I.%I( %L )$$
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

SELECT is(
  :s.function__arg_types($$IN in_int int, INOUT inout_int_array int[], OUT out_char "char", anyelement, boolean DEFAULT false$$)
  , '{int,int[],anyelement,boolean}'::regtype[]
  , 'Verify function__arg_types() with INOUT and OUT'
);

SELECT is(
  :s.function__arg_types($$IN in_int int, INOUT inout_int_array int[], anyarray, anyelement, boolean DEFAULT false$$)
  , '{int,int[],anyarray,anyelement,boolean}'::regtype[]
  , 'Verify function__arg_types() with just INOUT'
);

SELECT is(
  :s.function__arg_types($$IN in_int int, OUT out_char "char", anyarray, anyelement, boolean DEFAULT false$$)
  , '{int,anyarray,anyelement,boolean}'::regtype[]
  , 'Verify function__arg_types() with just OUT'
);

SELECT is(
  :s.function__arg_types($$anyelement, "char", pg_class, VARIADIC boolean[]$$)
  , '{anyelement,"\"char\"",pg_class,boolean[]}'::regtype[]
  , 'Verify function__arg_types() with only inputs'
);

\set args 'anyarray, OUT text, OUT "char", pg_class, int, VARIADIC boolean[]'
SELECT lives_ok(
  format(
    $$CREATE FUNCTION pg_temp.test_function(%s) LANGUAGE plpgsql AS $body$BEGIN NULL; END$body$;$$
    , :'args'
  )
  , format('Create pg_temp.test_function(%s)', :'args')
);

SELECT is(
  :s.regprocedure( 'pg_temp.test_function', :'args' )
  , 'pg_temp.test_function'::regproc::regprocedure
  , 'Verify regprocedure()'
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
