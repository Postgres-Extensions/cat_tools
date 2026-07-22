\set ECHO none

\i test/setup.sql

-- test_role is set in test/deps.sql

SET LOCAL ROLE :"use_role";

CREATE TEMP TABLE seqtest(s serial);
CREATE TEMP TABLE functions(fname name);
INSERT INTO functions SELECT unnest(
  '{currval, setval, nextval, sequence__next, sequence__last, sequence__set_next, sequence__set_last}'::text[]
);
CREATE TEMP VIEW fv AS
  SELECT 'cat_tools'::name AS sname, fname
      , (SELECT proargtypes::regtype[] FROM pg_proc WHERE oid=('cat_tools.' || fname)::regproc) AS args
    FROM functions
;

SELECT plan((
  0
  + (SELECT count(*) FROM functions) -- no_use tests
  + 4 * (SELECT count(*) FROM functions) -- definition

  +2 -- unset
  +2 -- next
  +8 -- set
  +3 -- currval
)::int);

GRANT SELECT ON functions TO public;
SET LOCAL ROLE :"no_use_role";
SELECT throws_ok(
  format( $$SELECT cat_tools.%I('seqtest', 's')$$, fname )
  , '42501' -- insufficient_privilege
  , NULL
  , format( 'Permission denied trying to use cat_tools.%I()', fname )
)
  FROM functions
;

SET LOCAL ROLE :"use_role";

SELECT function_returns( sname, fname, 'bigint'::regtype::text ) FROM fv;
SELECT volatility_is( sname, fname, 'volatile' ) FROM fv;
SELECT isnt_strict( sname, fname ) FROM fv;
SELECT isnt_definer( sname, fname ) FROM fv;

/*
 * unset
 */
SELECT throws_ok(
  format( $$SELECT cat_tools.%I('seqtest', 's')$$, fname )
  , '55000' -- object_not_in_prerequisite_state
  , NULL
  , 'Call on unset sequence throws error'
)
  FROM functions
  WHERE fname ~ 'currval|__last'
;

/*
 * next
 */
SELECT is(
  cat_tools.nextval('seqtest', 's')
  , 1::bigint
  , 'nextval returns correct value'
);
SELECT is(
  cat_tools.sequence__next('seqtest', 's')
  , 2::bigint -- Previous call to nextval incremented this...
  , 'sequence__next returns correct value'
);

/*
 * set
 */
SELECT is(
  cat_tools.setval('seqtest', 's', 2)
  , 2::bigint
  , 'setval returns correct value'
);
SELECT is(
  cat_tools.sequence__next('seqtest', 's')
  , 3::bigint
  , 'sequence__next returns correct value'
);
SELECT is(
  cat_tools.setval('seqtest', 's', 4, false)
  , 4::bigint
  , 'setval returns correct value'
);
SELECT is(
  cat_tools.sequence__next('seqtest', 's')
  , 4::bigint
  , 'sequence__next returns correct value'
);
SELECT is(
  cat_tools.sequence__set_last('seqtest', 's', 5)
  , 5::bigint
  , 'sequence__set_last returns correct value'
);
SELECT is(
  cat_tools.sequence__next('seqtest', 's')
  , 6::bigint
  , 'sequence__next returns correct value'
);
SELECT is(
  cat_tools.sequence__set_next('seqtest', 's', 7)
  , 7::bigint
  , 'sequence__set_next returns correct value'
);
SELECT is(
  cat_tools.sequence__next('seqtest', 's')
  , 7::bigint
  , 'sequence__next returns correct value'
);

/*
 * currval
 */
SELECT lives_ok(
  'INSERT INTO seqtest VALUES(default)'
  , 'INSERT INTO seqtest VALUES(default)'
);
SELECT is(
  cat_tools.currval('seqtest', 's')
  , 8::bigint
  , 'currval'
);
SELECT is(
  cat_tools.sequence__last('seqtest', 's')
  , 8::bigint
  , 'currval'
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
