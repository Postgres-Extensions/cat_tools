\set ECHO none

\i test/setup.sql

-- test_role is set in test/deps.sql

SET LOCAL ROLE :"use_role";
/*
 * Canonical (relkind, kind) pairs per pg_class.h, hard-coded so the assertions
 * below actually verify the mapping rather than re-encoding enum order.
 */
CREATE TEMP VIEW kinds(relkind, kind) AS
  VALUES
    ('r'::text, 'table'::text)
    , ('i', 'index')
    , ('S', 'sequence')
    , ('t', 'toast table')
    , ('v', 'view')
    , ('c', 'composite type')
    , ('f', 'foreign table')
    , ('m', 'materialized view')
;

SELECT plan(
  1
  + 2 -- Simple is() tests
  + 4 -- no_use tests
  + 3 * (SELECT count(*)::int FROM kinds)
);

SELECT is(
  (SELECT count(*)::int FROM kinds)
  , 8
  , 'Verify count from kinds'
);

SELECT is(
  cat_tools.relation__kind('r')
  , 'table'::cat_tools.relation_type
  , 'Simple sanity check of relation__kind()'
);
SELECT is(
  cat_tools.relation__relkind('table')
  , 'r'::cat_tools.relation_relkind
  , 'Simple sanity check of relation__relkind()'
);

SET LOCAL ROLE :"no_use_role";
SELECT throws_ok(
  format( 'SELECT NULL::%I', typename )
  , '42704' -- undefined_object; not exactly correct, but close enough
  , NULL
  , 'Permission denied trying to use types'
)
  FROM (VALUES
    ('cat_tools.relation__relkind')
    , ('cat_tools.relation__kind')
  ) v(typename)
;
SELECT throws_ok(
  format( 'SELECT cat_tools.relation__%s( NULL::%I )', suffix, argtype )
  , '42501' -- insufficient_privilege
  , NULL
  , 'Permission denied trying to run functions'
)
  FROM (VALUES
    ('kind', 'text'::regtype)
    , ('relkind', 'text'::regtype)
  ) v(suffix, argtype)
;

SET LOCAL ROLE :"use_role";

SELECT is(cat_tools.relation__relkind(kind)::text, relkind, format('SELECT cat_tools.relation_relkind(%L)', kind))
  FROM kinds
;

SELECT is(cat_tools.relation__kind(relkind)::text, kind, format('SELECT cat_tools.relation_type(%L)', relkind))
  FROM kinds
;

SELECT is(cat_tools.relation__kind(relkind::"char")::text, kind, format('SELECT cat_tools.relation_type(%L::"char")', relkind))
  FROM kinds
;

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
