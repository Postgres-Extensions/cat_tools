# sql-lint Design

## Type Name Preferences

Preferred names were determined by querying `pg_type` on PG17. All pairs are
true aliases (same OID). Preferences:

- SQL standard names where shorter: `int` (not `integer`), `varchar` (not
  `character varying`)
- SQL standard names where clearer: `smallint`/`bigint` (not `int2`/`int8`),
  `boolean` (not `bool`), `real` (not `float4`), `double precision` (not
  `float8`)
- Common short form: `numeric` (not `decimal`), `timestamp`/`timestamptz`
  (not the verbose `without/with time zone` forms)

NOT flagged: `text` vs `varchar` (semantically different — `varchar` has an
optional length constraint).

## Portability

Two spots are kept generic rather than hardcoded to this project, since
build conventions for what counts as "generated" vary:

- The directory walk in `bin/sql-lint` matches both `*.sql` and `*.sql.in` —
  cat_tools' hand-maintained SQL source is a `.sql.in` template expanded to
  `.sql` at build time, not a plain `.sql` file.
- `file_is_generated()` matches any first line containing both "GENERATED"
  and "DO NOT EDIT" (in either order), rather than one fixed marker string.

`lint.mk` also exposes `LINT_TARGETS` (default `sql/ test/`) so `make lint`
can be scoped to specific paths — e.g. to skip frozen version-snapshot files
that are tracked for update-path testing but, per project convention, are
never hand-edited again and so have no fixable findings.

## Future Rules

### Ready Now (line-level, no new infrastructure)

| Rule | Complexity | Description |
|---|---|---|
| **coalesce-boolean** | ~15 lines | Flag `COALESCE(expr, true/false)` — use `IS [NOT] TRUE` instead |
| **dollar-quote-naming** | ~15 lines | Flag bare `$$` and single-char `$x$` tags on multi-line blocks |

### Needs Small Helper (~10 lines of infra)

| Rule | Complexity | Description |
|---|---|---|
| **when-others-comment** | ~25 lines | `WHEN OTHERS` without explanatory comment on same/next line |
| **security-definer** | ~30 lines | `SECURITY DEFINER` without `SET search_path` nearby |

### Needs Statement Tracking Infrastructure

| Rule | Complexity | Description |
|---|---|---|
| **semicolon-placement** | ~50 lines + tracker | `;` on own line for multi-line statements |
| **comment-ordering** | ~80 lines + tracker + DDL extractor | `COMMENT ON` must follow its object |
| **variable-naming** | ~50 lines + dollar-quote awareness | PL/pgSQL `c_`/`v_`/`a_`/`r_` prefixes |

The statement boundary tracker is the key infrastructure piece — building it
unlocks semicolon-placement and comment-ordering. Variable-naming needs
separate dollar-quote block awareness.

The `lint/` directory structure supports adding linters for other languages
in the future (e.g. `lint/plpgsql/`, `lint/bash/`). Each linter is a
subdirectory with its own `Makefile`; `lint/Makefile` aggregates them.

## History

### Language Choice

The linter went through two iterations:

1. **Initial: Bash + AWK** (7 files, ~530 lines, 3 languages). Shipped fast
   but hit pain points: subshell variable loss, temp-file workarounds, awk
   embedded inside bash single-quotes (`\047` for single-quote), and no path
   to statement-level rules.

2. **Current: single Perl script**. Same rules, same output — but the scanner,
   suppression, and all rules live in one file with real data structures.

Why Perl over Go/Rust/Python:

| | Perl | Go/Rust | Python |
|---|---|---|---|
| Text processing | Native strength | Adequate | Adequate |
| Available everywhere | Yes (ships with every Unix) | Needs build pipeline | Yes (3.6+) |
| Statement-level rules | Natural (slurp + split) | Natural | Natural |
| Docker footprint | 15 MB | N/A (static binary) | 50 MB |

Go and Rust require a build/release pipeline that doesn't exist for this repo.
Python was considered but Perl is more concise for regex-heavy text processing.
