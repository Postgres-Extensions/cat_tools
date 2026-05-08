\set ECHO none

\i test/setup.sql

\set s cat_tools

SET LOCAL ROLE :use_role;

SELECT plan(
    (1 + 2 + 3 * array_length(cat_tools.enum_range('cat_tools.routine_type'), 1))
  + (1 + 2 + 3 * array_length(cat_tools.enum_range('cat_tools.routine_argument_mode'), 1))
  + (1 + 2 + 3 * array_length(cat_tools.enum_range('cat_tools.routine_volatility'), 1))
  + (1 + 2 + 3 * array_length(cat_tools.enum_range('cat_tools.routine_parallel_safety'), 1))
  + 32 -- routine__parse_arg_*, routine__arg_*, and security definer checks for routine__ callers
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
 * Test that the security check works when current_user != session_user
 * This tests what happens when functions are called from a different role context
 */
SET LOCAL ROLE :use_role;
SELECT throws_ok(
  $$SELECT cat_tools.routine__parse_arg_types('int')$$,
  '28000',
  'potential use of SECURITY DEFINER detected',
  'Security check should prevent execution when current_user != session_user'
);

/*
 * The helper functions now have security checks that prevent execution when
 * current_user != session_user (which happens with SET LOCAL ROLE).
 * Reset to session_user for testing the actual functionality.
 */
SET SESSION AUTHORIZATION :use_role;

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

-- Test new routine__arg_* functions that accept regprocedure
\set args 'anyarray, OUT text, OUT "char", pg_class, int, VARIADIC boolean[]'
SELECT lives_ok(
  format(
    $$CREATE FUNCTION pg_temp.test_function(%s) LANGUAGE plpgsql AS $body$BEGIN NULL; END$body$;$$
    , :'args'
  )
  , format('Create pg_temp.test_function(%s)', :'args')
);

-- Test routine__arg_types() - all argument types
SELECT is(
  :s.routine__arg_types(:s.regprocedure('pg_temp.test_function', :'args'))
  , '{anyarray,pg_class,integer,boolean[]}'::regtype[]
  , 'Verify routine__arg_types() returns all argument types'
);

-- Test routine__arg_types() with a function that has only IN arguments
SELECT is(
  :s.routine__arg_types('array_length(anyarray,integer)'::regprocedure)
  , '{anyarray,integer}'::regtype[]
  , 'Verify routine__arg_types() with IN arguments only'
);

-- Test routine__arg_types() with a function with no arguments
SELECT is(
  :s.routine__arg_types('pg_backend_pid()'::regprocedure)
  , '{}'::regtype[]
  , 'Verify routine__arg_types() with no arguments'
);

-- Test routine__arg_types() with a built-in function
SELECT is(
  :s.routine__arg_types('concat("any")'::regprocedure)
  , '{"\"any\""}'::regtype[]
  , 'Verify routine__arg_types() with VARIADIC argument'
);

-- Test routine__arg_names() - all argument names
SELECT is(
  :s.routine__arg_names(:s.regprocedure('pg_temp.test_function', :'args'))
  , '{NULL,NULL,NULL,NULL}'::text[]
  , 'Verify routine__arg_names() returns argument names (unnamed function)'
);

-- Create a function with named arguments for testing
SELECT lives_ok(
  $$CREATE FUNCTION pg_temp.named_function(input_val int, INOUT inout_val text, OUT output_val boolean) LANGUAGE plpgsql AS $body$BEGIN output_val := true; END$body$;$$
  , 'Create pg_temp.named_function with named arguments'
);

SELECT is(
  :s.routine__arg_names(:s.regprocedure('pg_temp.named_function', 'input_val int, INOUT inout_val text, OUT output_val boolean'))
  , '{input_val,inout_val}'::text[]
  , 'Verify routine__arg_names() with named arguments'
);

-- Test routine__arg_names() with no arguments
SELECT is(
  :s.routine__arg_names('pg_backend_pid()'::regprocedure)
  , '{}'::text[]
  , 'Verify routine__arg_names() with no arguments'
);

-- Test routine__arg_types_text() wrapper
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

-- Test routine__arg_names_text() wrapper
SELECT is(
  :s.routine__arg_names_text(:s.regprocedure('pg_temp.named_function', 'input_val int, INOUT inout_val text, OUT output_val boolean'))
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

/*
 * CRITICAL SECURITY TESTS: public routine__ functions must NOT be SECURITY DEFINER.
 * If they were, they could be exploited for SQL injection since they execute
 * dynamic SQL with elevated privileges.
 */

\set f routine__parse_arg_types
\set args_text 'text'
SELECT string_to_array(:'args_text', ', ') AS args \gset
SELECT isnt_definer(:'s', :'f', :'args'::name[]);

\set f routine__parse_arg_names
\set args_text 'text'
SELECT string_to_array(:'args_text', ', ') AS args \gset
SELECT isnt_definer(:'s', :'f', :'args'::name[]);

\set f routine__parse_arg_types_text
\set args_text 'text'
SELECT string_to_array(:'args_text', ', ') AS args \gset
SELECT isnt_definer(:'s', :'f', :'args'::name[]);

\set f routine__parse_arg_names_text
\set args_text 'text'
SELECT string_to_array(:'args_text', ', ') AS args \gset
SELECT isnt_definer(:'s', :'f', :'args'::name[]);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
