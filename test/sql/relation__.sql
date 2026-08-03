\set ECHO none

\i test/setup.sql

\set s cat_tools

SET LOCAL ROLE :"use_role";

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
  + 4 -- relation__is_catalog
  + 5 -- relation__column_names
  + 1 -- relkind drift check vs pg_class.h
  + 1 -- search_path still clean (test/finish.sql)
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
 * Drift check: every relkind the PostgreSQL we are built against defines must
 * appear in the hard-coded `kinds` data set above. test/gen-relkinds.sh (run by
 * `make`) extracts every RELKIND_* value from the server's pg_class.h into
 * pg_class_relkind_source; set_has() asserts `kinds` contains all of them. A
 * relkind in pg_class.h but missing from `kinds` means PostgreSQL added (or
 * renamed) one this extension does not handle yet -- fail so we notice and
 * update the enum, the mapping functions, and `kinds`.
 *
 * set_has() is a subset check, not equality, which is deliberate:
 *   - `kinds` listing a relkind an older PostgreSQL lacks is allowed.
 *   - when the server headers are unavailable pg_class_relkind_source is empty
 *     (see gen-relkinds.sh) and the empty set is trivially contained, so
 *     `make test` passes identically with or without postgresql-server-dev-NN.
 */
\i test/.generated/pg_class_relkinds.sql

SELECT set_has(
  $$SELECT relkind FROM kinds$$
  , $$SELECT relkind FROM pg_class_relkind_source$$
  , 'cat_tools handles every relkind defined in pg_class.h'
);

-- relation__is_temp
\set f relation__is_temp

SET LOCAL ROLE :"no_use_role";

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

SET LOCAL ROLE :"use_role";

SELECT is(
  cat_tools.relation__is_temp('pg_catalog.pg_class'::regclass)
  , false
  , 'pg_catalog.pg_class is not a temp relation'
);

/*
 * One temp table is shared by the relation__is_temp, relation__is_catalog and
 * relation__column_names tests below: a temp relation (hence not in pg_catalog)
 * with a known set of columns is everything those three functions need.
 */
SELECT lives_ok(
  $$CREATE TEMP TABLE rel_test(col1 int, col2 text, col3 boolean, col4 timestamp, col5 numeric)$$
  , 'Create shared temp table for is_temp/is_catalog/column_names tests'
);

SELECT is(
  cat_tools.relation__is_temp('rel_test'::regclass)
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

SET LOCAL ROLE :"no_use_role";

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

SET LOCAL ROLE :"use_role";

SELECT is(
  cat_tools.relation__is_catalog('pg_catalog.pg_class'::regclass)
  , true
  , 'pg_catalog.pg_class is in pg_catalog schema'
);

SELECT is(
  cat_tools.relation__is_catalog('rel_test'::regclass)
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

SET LOCAL ROLE :"no_use_role";

SELECT throws_ok(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , 'rel_test'
  )
  , '42501'
  , NULL
  , 'Verify public has no perms'
);

SET LOCAL ROLE :"use_role";

SELECT is(
  cat_tools.relation__column_names('rel_test'::regclass)
  , '{col1,col2,col3,col4,col5}'::text[]
  , 'Temp table returns expected column names'
);

SELECT lives_ok($$ALTER TABLE rel_test DROP COLUMN col3$$, 'Drop middle column from temp table');

SELECT is(
  cat_tools.relation__column_names('rel_test'::regclass)
  , '{col1,col2,col4,col5}'::text[]
  , 'Temp table with dropped column returns expected column names'
);

SELECT is(
  cat_tools.relation__column_names(NULL)
  , NULL
  , 'NULL input returns NULL (STRICT function)'
);

\i test/finish.sql

-- vi: expandtab ts=2 sw=2
