/*
 * Enum mapping helper: tests two sets of roundtrip behavior for a pair of
 * "char"-based and human-readable enums, preceded by a size check.
 *
 * Set 1 - Individual example (fully specified):
 *   Tests with a known sample value (sample_char -> sample_text), verifying
 *   that the mapping function returns exactly the right result.  This is the
 *   most meaningful correctness check because the expected output is
 *   externally specified rather than derived from the enum itself.
 *
 * Set 2 - All-values coverage (simpler roundtrip):
 *   For every value in both enums (via _enum_pairs view), verifies the
 *   mapping function does not return NULL/error when called with the enum
 *   type, the "char" type, and a plain text argument.  Breadth over depth.
 *
 * Required variables (set before \i):
 *   s           - schema name (typically already set globally, e.g. cat_tools)
 *   kind        - base name (e.g. type)
 *   char_col    - pg catalog column name (e.g. prokind)
 *   sample_char - one sample "char" value (e.g. f)
 *   sample_text - expected text result for sample_char (e.g. function)
 *
 * Internal variables (built here and unset at end):
 *   __f, __enum_type, __char_enum_type
 */
SELECT
    'routine__' || :'kind'               AS __f
  , 'cat_tools.routine_' || :'kind'     AS __enum_type
  , 'cat_tools.routine_' || :'char_col' AS __char_enum_type
\gset

CREATE OR REPLACE TEMP VIEW _enum_pairs AS
  SELECT
      (cat_tools.enum_range(:'__char_enum_type'))[gs]::text AS char_val
      , (cat_tools.enum_range(:'__enum_type'))[gs]::text    AS text_val
    FROM generate_series(
      1
      , greatest(
        /*
         * The two enums should be the same size; greatest() is used to
         * iterate both so that if they ever diverge we get a NULL failure
         * on the extra row rather than silently missing entries.
         * The size match is explicitly validated in Set 1 below.
         */
        array_length(cat_tools.enum_range(:'__enum_type'), 1)
        , array_length(cat_tools.enum_range(:'__char_enum_type'), 1)
      )
    ) gs
;

-- Prerequisite: both enums must be the same size

SELECT is(
    array_length(cat_tools.enum_range(:'__enum_type'), 1)
    , array_length(cat_tools.enum_range(:'__char_enum_type'), 1)
    , 'Verify ' || :'kind' || ' and ' || :'char_col' || ' enums have same size'
  );

-- Set 1: Individual example with fully specified expected value

SELECT is(
    :s.routine__:kind(:'sample_char')
    , :'sample_text'
    , 'Simple sanity check of ' || :'__f' || '()'
  );

SELECT is(
    :s.routine__:kind(:'sample_char':::__char_enum_type)
    , :'sample_text'
    , 'Simple sanity check of ' || :'__f' || '() with enum'
  );

-- Set 2: All-values coverage (simpler roundtrip across every enum entry)

SELECT is(
    :s.routine__:kind(char_val:::__char_enum_type)::text
    , text_val
    , format('SELECT ' || :'s' || '.' || :'__f' || '(%L::' || :'__char_enum_type' || ')', char_val)
  )
  FROM _enum_pairs
;

SELECT is(
    :s.routine__:kind(char_val::"char")::text
    , text_val
    , format('SELECT ' || :'s' || '.' || :'__f' || '(%L::"char")', char_val)
  )
  FROM _enum_pairs
;

SELECT is(
    :s.routine__:kind(char_val::"char")::text
    , text_val
    , format('SELECT ' || :'s' || '.' || :'__f' || '(%L)', char_val)
  )
  FROM _enum_pairs
;

\unset __f
\unset __enum_type
\unset __char_enum_type

-- vi: expandtab ts=2 sw=2
