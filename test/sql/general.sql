\set ECHO none

\i test/setup.sql

SELECT plan(
  0
  +1
  +1 -- search_path still clean (test/finish.sql)
);

SELECT hasnt_schema(
  '__cat_tools'
);

\i test/finish.sql
\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
