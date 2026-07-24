-- A single-line comment is fine.

-- Another single-line comment, separated by a blank line.

-- Two consecutive -- lines are also fine;
-- only a run of 3+ must become a /* */ block.

-- /* this is a line comment, not a block comment opening

--/* no space variant

-- This is a stacked comment -- sql-lint:disable comment-stacked-dashes
-- of three lines that would otherwise
-- be flagged, but is suppressed.

/*
 * This block comment contains lines that look like stacked dashes:
 * -- line one
 * -- line two
 * But they are inside a block comment and should NOT be flagged.
 */
