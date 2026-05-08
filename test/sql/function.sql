\set ECHO none

\i test/setup.sql

\set s cat_tools
\set _s _cat_tools

SELECT plan(
    2 -- security definer checks for _cat_tools helpers
  + 1 -- regprocedure()
  + 4 -- deprecated function__arg_types() wrappers
);

/*
 * CRITICAL SECURITY TESTS: Helper functions must NOT be SECURITY DEFINER.
 * If they were, they could be exploited for SQL injection since they execute
 * dynamic SQL.
 */

\set f function__arg_to_regprocedure
\set args_text 'text, text, text'
SELECT string_to_array(:'args_text', ', ') AS args \gset
SELECT isnt_definer(:'_s', :'f', :'args'::name[]);

\set f function__drop_temp
\set args_text 'regprocedure, text'
SELECT string_to_array(:'args_text', ', ') AS args \gset
SELECT isnt_definer(:'_s', :'f', :'args'::name[]);

/*
 * Deprecated wrappers call through to routine__parse_arg_types, which has a
 * security check that throws when current_user != session_user.  SET SESSION
 * AUTHORIZATION satisfies that check for the rest of this file.
 */
SET SESSION AUTHORIZATION :use_role;

SELECT is(
  :s.regprocedure('array_length', 'anyarray, integer')
  , 'array_length(anyarray,integer)'::regprocedure
  , 'Verify regprocedure()'
);

-- Test deprecated wrapper functions still work
\set VERBOSITY terse
SELECT is(
  :s.function__arg_types($$IN in_int int, INOUT inout_int_array int[], OUT out_char "char", anyelement, boolean DEFAULT false$$)
  , '{int,int[],anyelement,boolean}'::regtype[]
  , 'Verify deprecated function__arg_types() with INOUT and OUT'
);

SELECT is(
  :s.function__arg_types($$int, text$$)
  , '{int,text}'::regtype[]
  , 'Verify deprecated function__arg_types() with simple args'
);

SELECT is(
  :s.function__arg_types_text($$IN in_int int, INOUT inout_int_array int[], OUT out_char "char", anyelement, boolean DEFAULT false$$)
  , 'integer, integer[], anyelement, boolean'
  , 'Verify deprecated function__arg_types_text() with INOUT and OUT'
);

SELECT is(
  :s.function__arg_types_text($$int, text$$)
  , 'integer, text'
  , 'Verify deprecated function__arg_types_text() with simple args'
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
