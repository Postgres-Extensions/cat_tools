-- Pulls in deps.sql
\i test/pgxntool/setup.sql

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
