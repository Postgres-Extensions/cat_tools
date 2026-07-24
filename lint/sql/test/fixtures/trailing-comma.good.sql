/*
 * Lines that are pure -- comments should not trigger trailing-comma,
 * even if the comment text contains a comma.
 */

-- This is a comment with a trailing comma,

-- And another one with a comma,

SELECT column1     -- inline comment
	, column2      -- another inline comment
	, column3
FROM some_table
;

SELECT
	column1, -- sql-lint:disable trailing-comma
	column2
;

/*
 * Leading-comma items whose entire payload is a string literal are correct
 * leading-comma style and must NOT be flagged. (Regression: stripping the
 * string used to leave a bare leading comma that looked like a trailing one.)
 */
SELECT is(
	1
	, 'a description'
	, 'another, with an embedded comma'
);

CALL pg_temp.routine(
	'FUNCTION'
	, 'clean_routine_args'
	, 'args text'
);

-- A leading comma may sit alone on its line when it introduces a multi-line item.
SELECT row_eq(
	'SELECT ' || call
	, row(out)
	,
		'SELECT ' || call
		|| ' should return '
		|| coalesce(out::text, 'NULL')
);
