-- Pulls in deps.sql
\i test/pgxntool/setup.sql

/*
 * Self-check, not a toggle: pgxntool's own tap_setup.sql (just \i'd above)
 * sets search_path = tap, public for every test file -- cat_tools' own
 * schemas are never on it. That's what makes every pgTAP pass in this suite
 * mean cat_tools' internal views/functions fully schema-qualify their own
 * cross-references, rather than happening to resolve by search_path
 * accident. current_schemas(false) IS Postgres's own unqualified-name
 * search list, so confirming cat_tools/_cat_tools are absent from it is a
 * direct proof, not a proxy for one. Asserted here (always, unconditionally)
 * so a future change to the shared search_path baseline fails loudly instead
 * of silently widening what "passing" means.
 */
DO $$
BEGIN
  IF 'cat_tools' = ANY (current_schemas(false)) OR '_cat_tools' = ANY (current_schemas(false)) THEN
    RAISE EXCEPTION
      'cat_tools schema(s) must not be part of the resolved search_path during testing -- got %'
      , current_schemas(false)
    ;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA tap TO :"use_role", :"no_use_role";

CREATE FUNCTION pg_temp.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE sql;
END
$$;

CREATE FUNCTION pg_temp.major()
RETURNS int LANGUAGE sql IMMUTABLE AS $$
SELECT current_setting('server_version_num')::int/100
$$;

CREATE FUNCTION pg_temp.omit_column(
  rel text
  , omit name[] DEFAULT array['oid']
) RETURNS text LANGUAGE sql IMMUTABLE AS $body$
SELECT array_to_string(array(
    SELECT attname
      FROM pg_attribute a
      WHERE attrelid = rel::regclass
        AND NOT attisdropped
        AND attnum >= 0
        AND attname != ALL( omit )
      ORDER BY attnum
    )
  , ', '
)
$body$;



-- vi: expandtab ts=2 sw=2
