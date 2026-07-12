\set ECHO none

\i test/setup.sql

\set s cat_tools

SET LOCAL ROLE :use_role;

/*
 * Canonical pg_class.relkind -> cat_tools.relation_type mapping.
 *
 * These pairs are the ground truth per PostgreSQL's documented pg_class.relkind
 * semantics (src/include/catalog/pg_class.h RELKIND_* constants), and were
 * verified against the live catalog by creating one object of each kind and
 * reading back pg_class.relkind.
 *
 * They are hard-coded here on purpose. A previous version of this test built
 * `kinds` by positionally zipping enum_range('relation_type') against
 * enum_range('relation_relkind') and then asserted the mapping functions agreed
 * with that zip. Because the functions were written to the same positional
 * pairing, the test was tautological: an internally-consistent-but-wrong
 * mapping (e.g. c<->materialized view, f<->composite type, m<->foreign table
 * swapped) still passed. Asserting against these literal pairs makes the test
 * fail if the mapping is ever backwards.
 */
CREATE TEMP VIEW kinds (relkind, kind) AS
  VALUES
      ('r'::text, 'table'::text)
    , ('i', 'index')
    , ('S', 'sequence')
    , ('t', 'toast table')
    , ('v', 'view')
    , ('c', 'composite type')
    , ('f', 'foreign table')
    , ('m', 'materialized view')
    , ('p', 'partitioned table')
    , ('I', 'partitioned index')
;

SELECT plan(
  (1 + 2 + 2 * (SELECT count(*)::int FROM kinds)) -- relation_type enum mapping
  + 5 -- relation__is_temp
  + 5 -- relation__is_catalog
  + 8 -- relation__column_names
  + 1 -- relkind drift check vs pg_class.h
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

/*
 * Drift check: compare the hard-coded relkind data set above (`kinds`) against
 * the relkinds the PostgreSQL we are built against actually defines.
 * test/gen-relkinds.sh (run by `make`) extracts every RELKIND_* value from the
 * server's pg_class.h into pg_class_relkind_source. Any relkind present in
 * pg_class.h but absent from `kinds` means PostgreSQL added (or renamed) a
 * relkind this extension does not handle yet -- fail so we notice and update
 * the enum, the mapping functions, and `kinds`. The reverse (a relkind in
 * `kinds` that an older PostgreSQL lacks) is fine and intentionally ignored.
 *
 * Output is stable: string_agg over zero unknown relkinds is NULL, so the
 * assertion passes with the same TAP line on every supported PG version. When
 * the server headers are unavailable pg_class_relkind_source is empty (see
 * gen-relkinds.sh), which yields the same NULL/pass -- so `make test` produces
 * identical output with or without postgresql-server-dev-NN installed.
 */
\i test/generated/pg_class_relkinds.sql

SELECT is(
  (
    SELECT string_agg(src.relkind || ' (' || src.macro || ')', ', ' ORDER BY src.relkind)
      FROM pg_class_relkind_source AS src
      WHERE src.relkind NOT IN (SELECT relkind FROM kinds)
  )
  , NULL
  , 'pg_class.h defines no relkind missing from this test''s data set'
);

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
