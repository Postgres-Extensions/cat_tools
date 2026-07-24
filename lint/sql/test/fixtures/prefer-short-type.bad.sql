-- expect-findings: 9
CREATE TABLE long_types(
	long_types_id	integer		NOT NULL PRIMARY KEY
	, flag		bool		NOT NULL
	, name		character varying(100)	NOT NULL
	, amount	decimal		NOT NULL
	, score		float8
	, small_val	int2
	, big_val	int8
	, approx	float4
	, internal	int4
);
