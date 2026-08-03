\set ECHO none

\i test/setup.sql

\set s cat_tools
\set f name__check

SELECT plan(
  5
  + 1 -- search_path still clean (test/finish.sql)
);

SET LOCAL ROLE :"no_use_role";

SELECT throws_ok(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , 'x'
  )
  , '42501'
  , NULL
  , 'Verify public has no perms'
);

SET LOCAL ROLE :"use_role";

SELECT lives_ok(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , 'x'
  )
  , 'Simple name'
);
SELECT lives_ok(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , 'a b'
  )
  , 'Name with spaces'
);
SELECT lives_ok(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , NULL
  )
  , 'NULL'
);
SELECT throws_like(
  format(
    $$SELECT %I.%I( %L )$$
    , :'s', :'f'
    , repeat( 'x', pg_column_size( 'x'::name ) + 1 )
  )
  , '"%" becomes "%" when cast to name'
  , 'Error on overflow'
);

\i test/finish.sql

-- vi: expandtab ts=2 sw=2
