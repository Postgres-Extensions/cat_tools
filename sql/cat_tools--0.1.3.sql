DO $$
BEGIN
  CREATE ROLE cat_tools__usage NOLOGIN;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END
$$;

/*
 * NOTE: All pg_temp objects must be dropped at the end of the script!
 * Otherwise the eventual DROP CASCADE of pg_temp when the session ends will
 * also drop the extension! Instead of risking problems, create our own
 * "temporary" schema instead.
 */
CREATE SCHEMA __cat_tools;
CREATE FUNCTION __cat_tools.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  RAISE DEBUG 'sql = %', sql;
  EXECUTE sql;
END
$body$;
CREATE FUNCTION __cat_tools.create_function(
  function_name text
  , args text
  , options text
  , body text
  , grants text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE

  create_template CONSTANT text := $template$
CREATE OR REPLACE FUNCTION %s(
%s
) RETURNS %s AS
%L
$template$
  ;

  revoke_template CONSTANT text := $template$
REVOKE ALL ON FUNCTION %s(
%s
) FROM public;
$template$
  ;

  grant_template CONSTANT text := $template$
GRANT EXECUTE ON FUNCTION %s(
%s
) TO %s;
$template$
  ;

BEGIN
  PERFORM __cat_tools.exec( format(
      create_template
      , function_name
      , args
      , options
      , body
    ) )
  ;
  PERFORM __cat_tools.exec( format(
      revoke_template
      , function_name
      , args
    ) )
  ;

  IF grants IS NOT NULL THEN
    PERFORM __cat_tools.exec( format(
        grant_template
        , function_name
        , args
        , grants
      ) )
    ;
  END IF;
END
$body$;

CREATE SCHEMA cat_tools;
GRANT USAGE ON SCHEMA cat_tools TO cat_tools__usage;
CREATE SCHEMA _cat_tools;

CREATE OR REPLACE VIEW _cat_tools.pg_class_v AS
  SELECT c.oid AS reloid, c.*, n.nspname AS relschema
    FROM pg_class c
      LEFT JOIN pg_namespace n ON( n.oid = c.relnamespace )
;
REVOKE ALL ON _cat_tools.pg_class_v FROM public;

CREATE OR REPLACE VIEW cat_tools.pg_class_v AS
  SELECT *
    FROM _cat_tools.pg_class_v

    /*
     * Oddly, there's no security associated with schema or table visibility.
     * Be a bit paranoid though.
     */
    WHERE NOT pg_is_other_temp_schema(relnamespace)
      AND relkind IN( 'r', 'v', 'f' )
;
GRANT SELECT ON cat_tools.pg_class_v TO cat_tools__usage;

CREATE OR REPLACE VIEW _cat_tools.pg_attribute_v AS
  SELECT a.*
      , c.*
      , t.oid AS typoid
      , t.*
    FROM pg_attribute a
      LEFT JOIN _cat_tools.pg_class_v c ON ( c.reloid = a.attrelid )
      LEFT JOIN pg_type t ON ( t.oid = a.atttypid )
;
REVOKE ALL ON _cat_tools.pg_attribute_v FROM public;

CREATE OR REPLACE VIEW _cat_tools.column AS
  SELECT *
    , pg_catalog.format_type(typoid, atttypmod) AS column_type
    , CASE typtype
        -- domain
        WHEN 'd' THEN pg_catalog.format_type(typbasetype, typtypmod)
        -- enum
        WHEN 'e' THEN 'text' 
        ELSE pg_catalog.format_type(typoid, atttypmod)
      END AS base_type
    , pk.conkey AS pk_columns
    , ARRAY[attnum] <@ pk.conkey AS is_pk_member
    , (SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid)
          FROM pg_catalog.pg_attrdef d
          WHERE d.adrelid = a.attrelid
            AND d.adnum = a.attnum
            AND a.atthasdef
        ) AS column_default
    FROM _cat_tools.pg_attribute_v a
      LEFT JOIN pg_constraint pk
        ON ( reloid = pk.conrelid )
          AND pk.contype = 'p'
;
REVOKE ALL ON _cat_tools.column FROM public;

CREATE OR REPLACE VIEW cat_tools.column AS
  SELECT *
    FROM _cat_tools.column
    -- SECURITY
    WHERE NOT pg_is_other_temp_schema(relnamespace)
      AND attnum > 0
      AND NOT attisdropped
      AND relkind IN( 'r', 'v', 'f' )
      AND (
        pg_has_role(SESSION_USER, relowner, 'USAGE'::text)
        OR has_column_privilege(SESSION_USER, reloid, attnum, 'SELECT, INSERT, UPDATE, REFERENCES'::text)
      )
    ORDER BY relschema, relname, attnum
;
GRANT SELECT ON cat_tools.column TO cat_tools__usage;

-- Borrowed from newsysviews: http://pgfoundry.org/projects/newsysviews/
SELECT __cat_tools.create_function(
  '_cat_tools._pg_sv_column_array'
  , 'OID, SMALLINT[]'
  , 'NAME[] LANGUAGE sql STABLE'
  , $$
    SELECT ARRAY(
        SELECT a.attname
          FROM pg_catalog.pg_attribute a
          JOIN generate_series(1, array_upper($2, 1)) s(i) ON a.attnum = $2[i]
         WHERE attrelid = $1
         ORDER BY i
    )
$$
);

-- Borrowed from newsysviews: http://pgfoundry.org/projects/newsysviews/
SELECT __cat_tools.create_function(
  '_cat_tools._pg_sv_table_accessible'
  , 'OID, OID'
  , 'boolean LANGUAGE sql STABLE'
  , $$
    SELECT CASE WHEN has_schema_privilege($1, 'USAGE') THEN (
                  has_table_privilege($2, 'SELECT')
               OR has_table_privilege($2, 'INSERT')
               or has_table_privilege($2, 'UPDATE')
               OR has_table_privilege($2, 'DELETE')
               OR has_table_privilege($2, 'RULE')
               OR has_table_privilege($2, 'REFERENCES')
               OR has_table_privilege($2, 'TRIGGER')
           ) ELSE FALSE
    END;
$$
);

-- Borrowed from newsysviews: http://pgfoundry.org/projects/newsysviews/
CREATE OR REPLACE VIEW cat_tools.pg_all_foreign_keys
AS
  SELECT n1.nspname                                   AS fk_schema_name,
         c1.relname                                   AS fk_table_name,
         k1.conname                                   AS fk_constraint_name,
         c1.oid                                       AS fk_table_oid,
         _cat_tools._pg_sv_column_array(k1.conrelid,k1.conkey)   AS fk_columns,
         n2.nspname                                   AS pk_schema_name,
         c2.relname                                   AS pk_table_name,
         k2.conname                                   AS pk_constraint_name,
         c2.oid                                       AS pk_table_oid,
         ci.relname                                   AS pk_index_name,
         _cat_tools._pg_sv_column_array(k1.confrelid,k1.confkey) AS pk_columns,
         CASE k1.confmatchtype WHEN 'f' THEN 'FULL'
                               WHEN 'p' THEN 'PARTIAL'
                               WHEN 'u' THEN 'NONE'
                               else null
         END AS match_type,
         CASE k1.confdeltype WHEN 'a' THEN 'NO ACTION'
                             WHEN 'c' THEN 'CASCADE'
                             WHEN 'd' THEN 'SET DEFAULT'
                             WHEN 'n' THEN 'SET NULL'
                             WHEN 'r' THEN 'RESTRICT'
                             else null
         END AS on_delete,
         CASE k1.confupdtype WHEN 'a' THEN 'NO ACTION'
                             WHEN 'c' THEN 'CASCADE'
                             WHEN 'd' THEN 'SET DEFAULT'
                             WHEN 'n' THEN 'SET NULL'
                             WHEN 'r' THEN 'RESTRICT'
                             ELSE NULL
         END AS on_update,
         k1.condeferrable AS is_deferrable,
         k1.condeferred   AS is_deferred
    FROM pg_catalog.pg_constraint k1
    JOIN pg_catalog.pg_namespace n1 ON (n1.oid = k1.connamespace)
    JOIN pg_catalog.pg_class c1     ON (c1.oid = k1.conrelid)
    JOIN pg_catalog.pg_class c2     ON (c2.oid = k1.confrelid)
    JOIN pg_catalog.pg_namespace n2 ON (n2.oid = c2.relnamespace)
    JOIN pg_catalog.pg_depend d     ON (
                 d.classid = 'pg_constraint'::regclass
             AND d.objid = k1.oid
             AND d.objsubid = 0
             AND d.deptype = 'n'
             AND d.refclassid = 'pg_class'::regclass
             AND d.refobjsubid=0
         )
    JOIN pg_catalog.pg_class ci ON (ci.oid = d.refobjid AND ci.relkind = 'i')
    LEFT JOIN pg_depend d2      ON (
                 d2.classid = 'pg_class'::regclass
             AND d2.objid = ci.oid
             AND d2.objsubid = 0
             AND d2.deptype = 'i'
             AND d2.refclassid = 'pg_constraint'::regclass
             AND d2.refobjsubid = 0
         )
    LEFT JOIN pg_catalog.pg_constraint k2 ON (
                 k2.oid = d2.refobjid
             AND k2.contype IN ('p', 'u')
         )
   WHERE k1.conrelid != 0
     AND k1.confrelid != 0
     AND k1.contype = 'f'
     AND _cat_tools._pg_sv_table_accessible(n1.oid, c1.oid)
;
GRANT SELECT ON cat_tools.pg_all_foreign_keys TO cat_tools__usage;

SELECT __cat_tools.create_function(
  'cat_tools.currval'
  , $$
  table_name text
  , column_name text
$$
  , $$bigint LANGUAGE plpgsql$$
  , $body$
DECLARE
  seq regclass;
BEGIN
  -- Note: the function will throw an error if table or column doesn't exist
  seq := pg_get_serial_sequence( table_name, column_name );

  IF seq IS NULL THEN
    RAISE EXCEPTION '"%" is not a serial column', column_name
      USING ERRCODE = 'wrong_object_type'
        -- TODO: SCHEMA and COLUMN
        , COLUMN = column_name
    ;
  END IF;

  RETURN currval(seq);
END
$body$
  , 'cat_tools__usage'
);

SELECT __cat_tools.create_function(
  'cat_tools.enum_range'
  , 'enum regtype'
  , $$text[] LANGUAGE plpgsql STABLE$$
  , $body$
DECLARE
  ret text[];
BEGIN
  EXECUTE format('SELECT pg_catalog.enum_range( NULL::%s )', enum) INTO ret;
  RETURN ret;
END
$body$
  , 'cat_tools__usage'
);

SELECT __cat_tools.create_function(
  'cat_tools.enum_range_srf'
  , 'enum regtype'
  , $$SETOF text LANGUAGE sql$$
  , $body$
SELECT * FROM unnest( cat_tools.enum_range($1) ) AS r(enum_label)
$body$
  , 'cat_tools__usage'
);

SELECT __cat_tools.create_function(
  'cat_tools.pg_class'
  , 'rel regclass'
  , $$cat_tools.pg_class_v LANGUAGE sql STABLE$$
  , $body$
SELECT * FROM cat_tools.pg_class_v WHERE reloid = rel
$body$
  , 'cat_tools__usage'
);

SELECT __cat_tools.create_function(
  'cat_tools.name__check'
  , 'name_to_check text'
  , $$void LANGUAGE plpgsql$$
  , $body$
BEGIN
  IF name_to_check IS DISTINCT FROM name_to_check::name THEN
    RAISE '"%" becomes "%" when cast to name', name_to_check, name_to_check::name;
  END IF;
END
$body$
  , 'cat_tools__usage'
);

SELECT __cat_tools.create_function(
  'cat_tools.trigger__parse'
  , $$
  trigger_oid oid
  , OUT timing text
  , OUT events text[]
  , OUT defer text
  , OUT row_statement text
  , OUT when_clause text
  , OUT function_arguments text
$$
  , $$record LANGUAGE plpgsql$$
  , $body$
DECLARE
  r_trigger pg_catalog.pg_trigger;
  v_triggerdef text;
  v_create_stanza text;
  v_on_clause text;
  v_execute_clause text;

  v_work text;
  v_array text[];
BEGIN
  -- Do this first to make sure trigger exists
  v_triggerdef := pg_catalog.pg_get_triggerdef(trigger_oid, true);
  SELECT * INTO STRICT r_trigger FROM pg_catalog.pg_trigger WHERE oid = trigger_oid;

  v_create_stanza := format(
    'CREATE %sTRIGGER %I '
    , CASE WHEN r_trigger.tgconstraint=0 THEN '' ELSE 'CONSTRAINT ' END
    , r_trigger.tgname
  );
  -- Strip CREATE [CONSTRAINT] TRIGGER ... off
  v_work := replace( v_triggerdef, v_create_stanza, '' );

  -- Get BEFORE | AFTER | INSTEAD OF
  timing := split_part( v_work, ' ', 1 );
  timing := timing || CASE timing WHEN 'INSTEAD' THEN ' OF' ELSE '' END;

  -- Strip off timing clause
  v_work := replace( v_work, timing || ' ', '' );

  -- Get array of events (INSERT, UPDATE [OF column, column], DELETE, TRUNCATE)
  v_on_clause := ' ON ' || r_trigger.tgrelid::regclass || ' ';
  v_array := regexp_split_to_array( v_work, v_on_clause );
  events := string_to_array( v_array[1], ' OR ' );
  -- Get everything after ON table_name
  v_work := v_array[2];
  RAISE DEBUG 'v_work "%"', v_work;

  -- Strip off FROM referenced_table if we have it
  IF r_trigger.tgconstrrelid<>0 THEN
    v_work := replace(
      v_work
      , 'FROM ' || r_trigger.tgconstrrelid::regclass || ' '
      , ''
    );
  END IF;
  RAISE DEBUG 'v_work "%"', v_work;

  -- Get function arguments
  v_execute_clause := ' EXECUTE PROCEDURE ' || r_trigger.tgfoid::regproc || E'\\(';
  v_array := regexp_split_to_array( v_work, v_execute_clause );
  function_arguments := rtrim( v_array[2], ')' ); -- Yank trailing )
  -- Get everything prior to EXECUTE PROCEDURE ...
  v_work := v_array[1];
  RAISE DEBUG 'v_work "%"', v_work;

  row_statement := (regexp_matches( v_work, 'FOR EACH (ROW|STATEMENT)' ))[1];

  -- Get [ NOT DEFERRABLE | [ DEFERRABLE ] { INITIALLY IMMEDIATE | INITIALLY DEFERRED } ]
  v_array := regexp_split_to_array( v_work, 'FOR EACH (ROW|STATEMENT)' );
  RAISE DEBUG 'v_work = "%", v_array = "%"', v_work, v_array;
  defer := rtrim(v_array[1]);

  IF r_trigger.tgqual IS NOT NULL THEN
    when_clause := rtrim(
      (regexp_split_to_array( v_array[2], E' WHEN \\(' ))[2]
      , ')'
    );
  END IF;

  RAISE DEBUG
$$v_create_stanza = "%"
  v_on_clause = "%"
  v_execute_clause = "%"$$
    , v_create_stanza
    , v_on_clause
    , v_execute_clause
  ;

  RETURN;
END
$body$
  , 'cat_tools__usage'
);

SELECT __cat_tools.create_function(
  'cat_tools.trigger__get_oid__loose'
  , $$
  trigger_table regclass
  , trigger_name text
$$
  , $$oid LANGUAGE sql$$
  , $body$
  SELECT oid
    FROM pg_trigger
    WHERE tgrelid = trigger_table
      AND tgname = trigger_name
  ;
$body$
  , 'cat_tools__usage'
);

SELECT __cat_tools.create_function(
  'cat_tools.trigger__get_oid'
  , $$
  trigger_table regclass
  , trigger_name text
$$
  , $$oid LANGUAGE plpgsql$$
  , $body$
DECLARE
  v_oid oid;
BEGIN
  SELECT cat_tools.crigger__get_oid__loose( trigger_table, trigger_name )
    INTO STRICT v_oid
  ;

  RETURN v_oid;
END
$body$
  , 'cat_tools__usage'
);

DROP FUNCTION __cat_tools.exec(
  sql text
);
DROP FUNCTION __cat_tools.create_function(
  function_name text
  , args text
  , options text
  , body text
  , grants text
);
DROP SCHEMA __cat_tools;

-- vi: expandtab ts=2 sw=2
