/*
 * Enum mapping helper: tests roundtrip behavior for a pair of "char"-based
 * and human-readable enums.
 *
 * The two enums should be the same size; greatest() is used to iterate both
 * so that if they ever diverge we get a NULL failure on the extra row rather
 * than silently missing entries.
 *
 * Required variables (set before \i):
 *   s           - schema name (typically already set globally, e.g. cat_tools)
 *   kind        - base name (e.g. type)
 *   char_col    - pg catalog column name (e.g. prokind)
 *   sample_char - one sample "char" value (e.g. f)
 *   sample_text - expected text result for sample_char (e.g. function)
 *
 * Internal variables built here and unset at end:
 *   f, enum_type, char_enum_type
 */
SELECT
    'routine__' || :'kind'            AS f
  , 'cat_tools.routine_' || :'kind'  AS enum_type
  , 'cat_tools.routine_' || :'char_col' AS char_enum_type
\gset

CREATE OR REPLACE TEMP VIEW _enum_pairs AS
  SELECT
      (cat_tools.enum_range(:'char_enum_type'))[gs]::text AS char_val
      , (cat_tools.enum_range(:'enum_type'))[gs]::text    AS text_val
    FROM generate_series(
      1
      , greatest(
        array_length(cat_tools.enum_range(:'enum_type'), 1)
        , array_length(cat_tools.enum_range(:'char_enum_type'), 1)
      )
    ) gs
;

SELECT is(
    array_length(cat_tools.enum_range(:'enum_type'), 1)
    , array_length(cat_tools.enum_range(:'char_enum_type'), 1)
    , 'Verify count from ' || :'kind'
  );

SELECT is(
    :s.routine__:kind(:'sample_char')
    , :'sample_text'
    , 'Simple sanity check of ' || :'f' || '()'
  );

SELECT is(
    :s.routine__:kind(:'sample_char':::char_enum_type)
    , :'sample_text'
    , 'Simple sanity check of ' || :'f' || '() with enum'
  );

SELECT is(
    :s.routine__:kind(char_val:::char_enum_type)::text
    , text_val
    , format('SELECT ' || :'s' || '.' || :'f' || '(%L::' || :'char_enum_type' || ')', char_val)
  )
  FROM _enum_pairs
;

SELECT is(
    :s.routine__:kind(char_val::"char")::text
    , text_val
    , format('SELECT ' || :'s' || '.' || :'f' || '(%L::"char")', char_val)
  )
  FROM _enum_pairs
;

SELECT is(
    :s.routine__:kind(char_val::"char")::text
    , text_val
    , format('SELECT ' || :'s' || '.' || :'f' || '(%L)', char_val)
  )
  FROM _enum_pairs
;

\unset f
\unset enum_type
\unset char_enum_type
\unset kind
\unset char_col
\unset sample_char
\unset sample_text

-- vi: expandtab ts=2 sw=2
