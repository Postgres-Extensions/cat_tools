-- A single-line comment is fine.

-- Another single-line comment, separated by a blank line.

-- /* this is a line comment, not a block comment opening

--/* no space variant

-- This is stacked -- sql-lint:disable comment-stacked-dashes
-- but suppressed.

/*
 * This block comment contains lines that look like stacked dashes:
 * -- line one
 * -- line two
 * But they are inside a block comment and should NOT be flagged.
 */
