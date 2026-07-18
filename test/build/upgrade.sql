\set ECHO none
\i test/pgxntool/psql.sql
\t

/*
 * Regression guard for the CONDITIONAL 0.2.2->0.2.3 catalog-view rebuild.
 *
 * A fresh 0.2.2 install has CORRECT catalog views (built with the fixed
 * `!= ALL` omit_column), so the 0.2.2->0.2.3 update must leave the public view
 * chain -- cat_tools.pg_class_v, cat_tools.column, and the cat_tools.pg_class()
 * function -- and anything depending on it, in place. The old UNCONDITIONAL
 * DROP+CREATE would abort here: it drops those objects with no CASCADE, so the
 * dependents below would make ALTER EXTENSION UPDATE error out (failing this
 * build test). The conditional rebuild skips a correct install, so the
 * dependents survive.
 */
BEGIN;
CREATE EXTENSION cat_tools VERSION '0.2.2';

CREATE VIEW pg_temp.dep_on_pg_class_v AS SELECT * FROM cat_tools.pg_class_v;
CREATE VIEW pg_temp.dep_on_column AS SELECT * FROM cat_tools.column;

-- Suppress any expected notices from the update so build.out stays empty.
SET LOCAL client_min_messages = ERROR;
ALTER EXTENSION cat_tools UPDATE;

/*
 * Prove the dependents still exist and are queryable after the update; a bare
 * DO block emits no output, so the expected build output stays empty.
 */
DO $$
BEGIN
  PERFORM 1 FROM pg_temp.dep_on_pg_class_v;
  PERFORM 1 FROM pg_temp.dep_on_column;
END
$$;
ROLLBACK;

-- vi: expandtab sw=2 ts=2
