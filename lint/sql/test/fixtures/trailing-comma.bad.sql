-- expect-findings: 7
SELECT
	column1,
	column2,
	column3
FROM some_table
;

CREATE TABLE bad_table(
	id serial NOT NULL PRIMARY KEY,
	name text NOT NULL,
	status text
);

INSERT INTO t(a, b, c)
VALUES (
	1,
	2,
	3
);

/*
 * A genuine trailing comma after a lone string literal must still be caught
 * (the sentinel keeps the comma on the trailing side after string-stripping).
 */
INSERT INTO t(a)
VALUES (
	'x',
	'y'
);
