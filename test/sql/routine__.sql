\set ECHO none

\i test/setup.sql

\set s cat_tools

SET LOCAL ROLE :use_role;

SELECT plan(
    (1 + 2 + 3 * array_length(cat_tools.enum_range('cat_tools.routine_type'), 1))
  + (1 + 2 + 3 * array_length(cat_tools.enum_range('cat_tools.routine_argument_mode'), 1))
  + (1 + 2 + 3 * array_length(cat_tools.enum_range('cat_tools.routine_volatility'), 1))
  + (1 + 2 + 3 * array_length(cat_tools.enum_range('cat_tools.routine_parallel_safety'), 1))
  + 2  -- no_use_role access denied for parse helpers (throws_ok via func_calls)
  + 1  -- security check when current_user != session_user
  + 1  -- create pg_temp.test_function
  + 1  -- create pg_temp.named_function
  + 4  -- routine__parse_arg_types() tests
  + 1  -- isnt_definer: routine__parse_arg_types
  + 1  -- isnt_definer: routine__parse_arg_types_text
  + 4  -- routine__arg_types() tests
  + 4  -- routine__arg_types_text() tests
  + 4  -- routine__parse_arg_names() tests
  + 1  -- isnt_definer: routine__parse_arg_names
  + 1  -- isnt_definer: routine__parse_arg_names_text
  + 3  -- routine__arg_names() tests
  + 4  -- routine__arg_names_text() tests
);

\set kind        type
\set char_col    prokind
\set sample_char f
\set sample_text function
\i test/helpers/enum_mapping.sql

\set kind        argument_mode
\set char_col    proargmode
\set sample_char i
\set sample_text in
\i test/helpers/enum_mapping.sql

\set kind        volatility
\set char_col    provolatile
\set sample_char i
\set sample_text immutable
\i test/helpers/enum_mapping.sql

\set kind        parallel_safety
\set char_col    proparallel
\set sample_char s
\set sample_text safe
\i test/helpers/enum_mapping.sql

CREATE TEMP VIEW func_calls AS
  SELECT * FROM (VALUES
    ('routine__parse_arg_types'::name, $$'x'$$::text)
    , ('routine__parse_arg_names'::name, $$'x'$$::text)
  ) v(fname, args)
;
GRANT SELECT ON func_calls TO public;

SET LOCAL ROLE :no_use_role;

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

/*
 * Test that the security check works when current_user != session_user.
 * SET LOCAL ROLE makes current_user = use_role while session_user = superuser,
 * so current_user != session_user, and the function should throw 28000.
 */
SET LOCAL ROLE :use_role;
SELECT throws_ok(
  $$SELECT cat_tools.routine__parse_arg_types('int')$$
  , '28000'
  , 'potential use of SECURITY DEFINER detected'
  , 'Security check should prevent execution when current_user != session_user'
);

/*
 * SET SESSION AUTHORIZATION satisfies the current_user = session_user check
 * required by the parse helper security guard.  All functional tests below
 * run under this authorization.
 */
SET SESSION AUTHORIZATION :use_role;

/*
 * routine__parse_arg_types / routine__parse_arg_types_text
 */

SELECT is(
  :s.routine__parse_arg_types($$IN in_int int, INOUT inout_int_array int[], OUT out_char "char", anyelement, boolean DEFAULT false$$)
  , '{int,int[],anyelement,boolean}'::regtype[]
  , 'Verify routine__parse_arg_types() with INOUT and OUT'
);

SELECT is(
  :s.routine__parse_arg_types($$IN in_int int, INOUT inout_int_array int[], anyarray, anyelement, boolean DEFAULT false$$)
  , '{int,int[],anyarray,anyelement,boolean}'::regtype[]
  , 'Verify routine__parse_arg_types() with just INOUT'
);

SELECT is(
  :s.routine__parse_arg_types($$IN in_int int, OUT out_char "char", anyarray, anyelement, boolean DEFAULT false$$)
  , '{int,anyarray,anyelement,boolean}'::regtype[]
  , 'Verify routine__parse_arg_types() with just OUT'
);

SELECT is(
  :s.routine__parse_arg_types($$anyelement, "char", pg_class, VARIADIC boolean[]$$)
  , '{anyelement,"\"char\"",pg_class,boolean[]}'::regtype[]
  , 'Verify routine__parse_arg_types() with only inputs'
);

/*
 * CRITICAL SECURITY TESTS: public routine__ functions must NOT be SECURITY DEFINER.
 * If they were, they could be exploited for SQL injection since they execute
 * dynamic SQL with elevated privileges.
 */

\set f routine__parse_arg_types
SELECT string_to_array('text', ', ') AS _f_args \gset
SELECT isnt_definer(:'s', :'f', :'_f_args'::name[]);

\set f routine__parse_arg_types_text
SELECT isnt_definer(:'s', :'f', :'_f_args'::name[]);

/*
 * Create pg_temp test functions now that we have a stable session_user.
 * These are used by the routine__arg_types and routine__arg_names tests below.
 */
\set args 'anyarray, OUT text, OUT "char", pg_class, int, VARIADIC boolean[]'
\set named_args 'input_val int, INOUT inout_val text, OUT output_val boolean'
SELECT lives_ok(
  format(
    $$CREATE FUNCTION pg_temp.test_function(%s) LANGUAGE plpgsql AS $body$BEGIN NULL; END$body$;$$
    , :'args'
  )
  , format('Create pg_temp.test_function(%s)', :'args')
);

SELECT lives_ok(
  format(
    $$CREATE FUNCTION pg_temp.named_function(%s) LANGUAGE plpgsql AS $body$BEGIN output_val := true; END$body$;$$
    , :'named_args'
  )
  , format('Create pg_temp.named_function(%s)', :'named_args')
);

/*
 * routine__arg_types / routine__arg_types_text
 */

SELECT is(
  :s.routine__arg_types(:s.regprocedure('pg_temp.test_function', :'args'))
  , '{anyarray,pg_class,integer,boolean[]}'::regtype[]
  , 'Verify routine__arg_types() returns all argument types'
);

SELECT is(
  :s.routine__arg_types('array_length(anyarray,integer)'::regprocedure)
  , '{anyarray,integer}'::regtype[]
  , 'Verify routine__arg_types() with IN arguments only'
);

SELECT is(
  :s.routine__arg_types('pg_backend_pid()'::regprocedure)
  , '{}'::regtype[]
  , 'Verify routine__arg_types() with no arguments'
);

SELECT is(
  :s.routine__arg_types('concat("any")'::regprocedure)
  , '{"\"any\""}'::regtype[]
  , 'Verify routine__arg_types() with VARIADIC argument'
);

SELECT is(
  :s.routine__arg_types_text(:s.regprocedure('pg_temp.test_function', :'args'))
  , 'anyarray, pg_class, integer, boolean[]'
  , 'Verify routine__arg_types_text() formatting'
);

SELECT is(
  :s.routine__arg_types_text('array_length(anyarray,integer)'::regprocedure)
  , 'anyarray, integer'
  , 'Verify routine__arg_types_text() with simple types'
);

SELECT is(
  :s.routine__arg_types_text('pg_backend_pid()'::regprocedure)
  , ''
  , 'Verify routine__arg_types_text() with no arguments'
);

SELECT is(
  :s.routine__arg_types_text('concat("any")'::regprocedure)
  , '"any"'
  , 'Verify routine__arg_types_text() with VARIADIC'
);

/*
 * routine__parse_arg_names / routine__parse_arg_names_text
 */

SELECT is(
  :s.routine__parse_arg_names($$IN in_int int, INOUT inout_int_array int[], OUT out_char "char", anyelement, boolean DEFAULT false$$)
  , '{in_int,inout_int_array,NULL,NULL}'::text[]
  , 'Verify routine__parse_arg_names() with INOUT and OUT'
);

SELECT is(
  :s.routine__parse_arg_names($$IN in_int int, INOUT inout_int_array int[], anyarray, anyelement, boolean DEFAULT false$$)
  , '{in_int,inout_int_array,NULL,NULL,NULL}'::text[]
  , 'Verify routine__parse_arg_names() with just INOUT'
);

SELECT is(
  :s.routine__parse_arg_names($$IN in_int int, OUT out_char "char", anyarray, anyelement, boolean DEFAULT false$$)
  , '{in_int,NULL,NULL,NULL}'::text[]
  , 'Verify routine__parse_arg_names() with just OUT'
);

SELECT is(
  :s.routine__parse_arg_names($$anyelement, "char", pg_class, VARIADIC boolean[]$$)
  , '{NULL,NULL,NULL,NULL}'::text[]
  , 'Verify routine__parse_arg_names() with only inputs'
);

\set f routine__parse_arg_names
SELECT isnt_definer(:'s', :'f', :'_f_args'::name[]);

\set f routine__parse_arg_names_text
SELECT isnt_definer(:'s', :'f', :'_f_args'::name[]);

/*
 * routine__arg_names / routine__arg_names_text
 */

SELECT is(
  :s.routine__arg_names(:s.regprocedure('pg_temp.test_function', :'args'))
  , '{NULL,NULL,NULL,NULL}'::text[]
  , 'Verify routine__arg_names() returns argument names (unnamed function)'
);

SELECT is(
  :s.routine__arg_names(:s.regprocedure('pg_temp.named_function', :'named_args'))
  , '{input_val,inout_val}'::text[]
  , 'Verify routine__arg_names() with named arguments'
);

SELECT is(
  :s.routine__arg_names('pg_backend_pid()'::regprocedure)
  , '{}'::text[]
  , 'Verify routine__arg_names() with no arguments'
);

SELECT is(
  :s.routine__arg_names_text(:s.regprocedure('pg_temp.named_function', :'named_args'))
  , 'input_val, inout_val'
  , 'Verify routine__arg_names_text() formatting'
);

SELECT is(
  :s.routine__arg_names_text(:s.regprocedure('pg_temp.test_function', :'args'))
  , ''
  , 'Verify routine__arg_names_text() with unnamed arguments'
);

SELECT is(
  :s.routine__arg_names_text('array_length(anyarray,integer)'::regprocedure)
  , ''
  , 'Verify routine__arg_names_text() with built-in function'
);

SELECT is(
  :s.routine__arg_names_text('pg_backend_pid()'::regprocedure)
  , ''
  , 'Verify routine__arg_names_text() with no arguments'
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
