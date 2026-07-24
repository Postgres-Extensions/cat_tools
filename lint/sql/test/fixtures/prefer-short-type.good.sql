CREATE TABLE short_types(
	short_types_id	int		NOT NULL PRIMARY KEY
	, flag		boolean		NOT NULL
	, name		varchar(100)	NOT NULL
	, label		text		NOT NULL
	, amount	numeric		NOT NULL
	, score		double precision
	, small_val	smallint
	, big_val	bigint
	, approx	real
	, ts		timestamp
	, tstz		timestamptz
);
/*
 * Type names inside identifiers should not be flagged.
 * "is_real_value", "integer_count", "boolean_flag" are identifiers, not types.
 */
CREATE FUNCTION is_real_value(integer_count int, boolean_flag boolean) RETURNS boolean
LANGUAGE sql AS $$SELECT true$$;
