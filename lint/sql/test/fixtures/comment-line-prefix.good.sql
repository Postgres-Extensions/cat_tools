/*
 * Every content line starts with " * ".
 * Including this one.
 */

/* sql-lint:disable-block all
A disable-block directive on the opening line exempts the whole block, so code
commented out like this needs no " * " prefixes on each line.
SELECT not_ready_yet(
  foo
  , bar
);
*/

/* EXCLUDED CODE — the friendly alias for disable-block all, for commented-out code
SELECT also_not_ready(
  foo
  , bar
);
*/
