\set ECHO none

\i test/setup.sql

\set s cat_tools

CREATE TEMP VIEW views AS
  SELECT * FROM (VALUES
    ('_cat_tools'::name, 'pg_depend_identity_v'::name)
  ) v(view_schema, view_name)
;
GRANT SELECT ON views TO public;

/*
 * The pg_depends tests are problematic, because bag_eq creates temp objects,
 * which then do not show up in pg_dep or the view. So we need to capture what
 * things look like before actually running the test. The same problem exists
 * with creating 2 separate views; first we have to create the views, then
 * insert the data into them.
 */
SELECT CASE
WHEN pg_temp.major() >= 903 THEN pg_temp.exec($exec$
  CREATE TEMP TABLE pg_dep AS SELECT * FROM pg_depend WHERE false;
  CREATE TEMP TABLE pg_dep_v AS SELECT * FROM pg_dep;
  INSERT INTO pg_dep_v SELECT classid, objid, objsubid, refclassid, refobjid, refobjsubid, deptype FROM _cat_tools.pg_depend_identity_v;
  INSERT INTO pg_dep SELECT * FROM pg_depend;
$exec$)
END;

SELECT plan(
  0
  -- Perms
  + (SELECT count(*)::int FROM views)
  --+ (SELECT count(*)::int FROM func_calls)

  + 1 -- _cat_tools.pg_depend_v
  + 1 -- search_path still clean (test/finish.sql)
);

/*
 * Tests to run as owner!
 */


/*
 * _cat_tools.pg_depend_v
 */
\set call 'SELECT * FROM %I.%I'
\set call_some 'SELECT classid, objid, objsubid, refclassid, refobjid, refobjsubid, deptype FROM %I.%I'
\set s _cat_tools
\set n pg_depend_identity_v

SELECT CASE
  WHEN pg_temp.major() < 903 THEN
    pass(
      format('Verify base data on ', :'s', :'n')
    )
  ELSE
    bag_eq(
      $$SELECT * FROM pg_dep_v$$
      , $$SELECT * FROM pg_dep$$
      , format('Verify base data on ', :'s', :'n')
    )
END;

/*
 * END tests to run as owner
 */

SET LOCAL ROLE :"no_use_role";

SELECT CASE
  WHEN pg_temp.major() < 903 THEN
    pass(
      'Verify public has no perms'
    )
  ELSE
    throws_ok(
      format(
        $$SELECT * FROM %I.%I$$
        , view_schema, view_name
      )
      , '42501'
      , NULL
      , 'Verify public has no perms'
    )
  END
  FROM views
;

SET LOCAL ROLE :"use_role";

\i test/finish.sql

-- vi: expandtab ts=2 sw=2
