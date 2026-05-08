\set ECHO none

\i test/setup.sql

/*
 * Dynamically verify the permission model for the entire cat_tools public API:
 *   - no_use_role (no cat_tools__usage grant) cannot use any type or execute any function
 *   - use_role (has cat_tools__usage) can use all types and execute all functions
 *
 * Views are created as superuser so both roles can read them via explicit grants.
 */
CREATE TEMP VIEW cat_types AS
SELECT 'cat_tools.' || typname AS type_name
  FROM pg_type t
  WHERE t.typnamespace = 'cat_tools'::regnamespace
    AND t.typtype IN ('e', 'c') -- enums and composite types
  ORDER BY typname
;
GRANT SELECT ON cat_types TO :use_role, :no_use_role;

CREATE TEMP VIEW cat_functions AS
SELECT p.oid, p.proname, pg_get_function_arguments(p.oid) AS args
  FROM pg_proc p
  WHERE p.pronamespace = 'cat_tools'::regnamespace
  ORDER BY proname, pg_get_function_arguments(p.oid)
;
GRANT SELECT ON cat_functions TO :use_role, :no_use_role;

SELECT plan(
    (SELECT count(*)::int FROM cat_types) * 2      -- no_use denied + use allowed
  + (SELECT count(*)::int FROM cat_functions) * 2  -- no_use denied + use allowed
);

/*
 * Function privilege checks via pg_catalog privilege functions.
 * has_function_privilege(user, func, priv) checks the named role's privilege
 * including inherited roles, independent of the current session role.
 */
SELECT is(
    has_function_privilege(:'no_use_role', oid, 'EXECUTE')
    , false
    , format('Permission denied trying to execute cat_tools.%s(%s)', proname, args)
  )
  FROM cat_functions
;

SELECT is(
    has_function_privilege(:'use_role', oid, 'EXECUTE')
    , true
    , format('Permission granted to execute cat_tools.%s(%s)', proname, args)
  )
  FROM cat_functions
;

/*
 * Type access checks via role switching.
 * Attempts actual casts to verify enforcement at the SQL level.
 */
SET LOCAL ROLE :no_use_role;

SELECT throws_ok(
    format('SELECT NULL::%s', type_name)
    , '42501'
    , NULL
    , format('Permission denied trying to use type %s', type_name)
  )
  FROM cat_types
;

SET LOCAL ROLE :use_role;

SELECT lives_ok(
    format('SELECT NULL::%s', type_name)
    , format('Permission granted to use type %s', type_name)
  )
  FROM cat_types
;

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
