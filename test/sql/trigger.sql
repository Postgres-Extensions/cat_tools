\set ECHO none

\i test/setup.sql

\set s cat_tools
\set function_array_text '{trigger__get_oid,trigger__get_oid__loose,trigger__parse}'
\set function_array array[:'function_array_text'::name[]]

SELECT plan(
  0

  + 3 -- no perms

  + 1 -- loose returns null
  + 3 -- other undefined_object tests

  + 2 -- verify trigger__parse output

  + 1 -- verify trigger__args_as_array()

  + 1 -- search_path still clean (test/finish.sql)
);

SET LOCAL ROLE :"no_use_role";

SELECT throws_ok(
      format(
        $$SELECT %I.%I( %L )$$
        , :'s', f
        , 'x'
      )
      , '42501'
      , NULL
      , 'Verify public has no perms'
    )
  FROM unnest(:function_array) f
;

SET LOCAL ROLE :"use_role";

CREATE TEMP TABLE "test table"();

SELECT is(
  cat_tools.trigger__get_oid__loose('"test table"', '"test trigger"')
  , NULL
  , 'loose returns NULL for missing trigger'
);
SELECT throws_ok(
  'SELECT ' || call
  , '42704'
  , 'trigger "test trigger" on table "test table" does not exist'
  , call || ' throws correct error for missing trigger'
)
  FROM (
    SELECT
      format(
        $$%I.%I( %L, %L )$$
        , :'s', f
        , '"test table"'
        , '"test trigger"'
      ) AS call
      FROM unnest(:function_array) f
      WHERE f !~ 'loose'
  ) u
;
SELECT throws_ok(
  format(
    $$SELECT %I.%I( %s )$$
    , :'s', 'trigger__parse'
    , 'pg_class'::regclass::oid -- OID that's guaranteed not to be a trigger
  )
  , '42704'
  , 'trigger with OID ' || 'pg_class'::regclass::oid || ' does not exist'
  , format(
    $$SELECT %I.%I( %s )$$
    , :'s', 'trigger__parse'
    , 'pg_class'::regclass::oid -- OID that's guaranteed not to be a trigger
  )
    || ' throws correct error for missing trigger'
);

CREATE FUNCTION pg_temp.tg(
) RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  RETURN NEW;
END$body$;

CREATE CONSTRAINT TRIGGER "test trigger" AFTER INSERT OR DELETE
  ON "test table"
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (true)
  EXECUTE PROCEDURE pg_temp.tg(
    'argument 1', NULL, 'argument, with, comma', 3
  )
;

CREATE TEMP TABLE expected(
  -- s/OUT //
  timing text
  , events text[]
  , defer text
  , row_statement text
  , when_clause text
  , trigger_function regprocedure
  , function_arguments text[]
);

INSERT INTO expected VALUES(
    'AFTER'
    , '{INSERT,DELETE}'::text[]
    , 'DEFERRABLE INITIALLY DEFERRED'
    , 'ROW'
    , 'true'
    , 'pg_temp.tg()'::regprocedure
    , array[
      'argument 1', 'null', 'argument, with, comma', '3'
    ]
  )
;

SELECT results_eq(
  format(
    $$SELECT * FROM %I.%I( %I.%I(%L, %L) )$$
    , :'s', 'trigger__parse'
    , :'s', 'trigger__get_oid'
    , '"test table"'
    , '"test trigger"'
  )
  , $$SELECT '"test table"'::regclass, * FROM expected$$
  , 'verify results of trigger__parse(oid)'
);
SELECT results_eq(
  format(
    $$SELECT * FROM %I.%I( %L, %L )$$
    , :'s', 'trigger__parse'
    , '"test table"'
    , '"test trigger"'
  )
  , $$SELECT * FROM expected$$
  , 'verify results of trigger__parse(regclass,text)'
);

SELECT is(
  cat_tools.trigger__args_as_text(
    array[
      'argument 1', 'null', 'argument, with, comma', '3'
    ]
  )
  , $$'argument 1', 'null', 'argument, with, comma', '3'$$
  , 'verify trigger__args_as_text()'
);

\i test/finish.sql
\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
