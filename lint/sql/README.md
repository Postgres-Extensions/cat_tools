# sql-lint

Style linter for PostgreSQL SQL files. Enforces this project's SQL coding
conventions (block comments, leading commas, short type names — see the
"SQL file conventions" and "Code Style" sections of `CLAUDE.md`).

## Quick Start

```bash
# Lint the project's SQL from the repo root (paths are set in Makefile's
# LINT_TARGETS; see lint/lint.mk)
make lint

# Run the linter directly on specific files or directories
lint/sql/bin/sql-lint sql/cat_tools.sql.in test/
```

## Usage

```
sql-lint [OPTIONS] FILE...
sql-lint [OPTIONS] DIRECTORY...
```

Files are checked against all enabled rules. Directories are searched
recursively for `*.sql` and `*.sql.in` files (excluding `deps/`,
`docker/deps/`, `pgxntool/`, and `.claude/worktrees/`).

### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message |
| `-q`, `--quiet` | Suppress the summary line |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | No findings |
| 1-10 | Reserved for generic errors (2 = usage error) |
| 11+ | Lint findings: `exit_code - 10` = number of findings |

Note: exit codes are capped at 255 by POSIX, so 245+ findings all exit 255.

## Rules

All comment formatting rules share the `comment-` prefix so they sort
together in fixture listings.

### comment-closing

Block comments must end with `*/` alone on its own line.

```sql
/*
 * Bad: text before closing */

/*
 * Good: closing on its own line.
 */
```

### comment-line-prefix

Lines inside a block comment must start with ` * `.

```sql
/*
   Bad: missing the star prefix.
 * Good: has the star prefix.
 */
```

### comment-opening

Block comments must start with `/*` alone on the opening line.

```sql
/* Bad: text on the opening line
 * of a multi-line comment
 */

/*
 * Good: opening line has only /*
 */
```

### comment-padding

Block comments must not have blank `*` lines immediately after `/*`
or immediately before `*/`.

```sql
/*
 *
 * Bad: leading blank line above.
 */

/*
 * Good: content starts immediately.
 */
```

### comment-single-line

Single-line `/* text */` comments are not allowed. Use `--` for
single-line comments.

```sql
/* Bad: single-line block comment */

-- Good: use a line comment instead
```

### comment-stacked-dashes

A run of 3 or more consecutive `--` lines must use `/* */` syntax instead.
Up to 2 consecutive `--` lines is fine — a short remark reads fine as `--`.

```sql
-- Bad: stacked dashes
-- spanning three
-- or more lines

-- Good: 2 lines is fine
-- as a short remark

/*
 * Good: block comment
 * for anything longer
 */
```

### trailing-comma

Multi-line constructs must use leading commas (`, item`), not trailing
commas (`item,`).

```sql
-- Bad
SELECT
    column1,
    column2,
    column3

-- Good
SELECT
    column1
    , column2
    , column3
```

### prefer-short-type

Use short-form type names where PostgreSQL provides them. `text` and
`varchar` are not interchangeable and are not flagged against each other.

| Don't use | Use instead |
|-------------|-----------|
| `integer`, `int4` | `int` |
| `bool` | `boolean` |
| `character varying` | `varchar` |
| `float8` | `double precision` |
| `float4` | `real` |
| `int2` | `smallint` |
| `int8` | `bigint` |
| `decimal` | `numeric` |
| `timestamp without time zone` | `timestamp` |
| `timestamp with time zone` | `timestamptz` |
| `time without time zone` | `time` |
| `time with time zone` | `timetz` |

## Inline Suppression

Suppress a finding on a specific line:

```sql
SELECT something, -- sql-lint:disable trailing-comma
```

`disable` and `disable-line` both apply to the line they appear on;
`disable-next-line` applies to the following line. Use `all` in place of a
rule id to suppress every rule.

```sql
-- sql-lint:disable-next-line trailing-comma
SELECT something,
```

### Block suppression

A `disable-block <rule|all>` directive on the line that opens a `/* */` block
comment suppresses the rule for every line in that block.

For the common case — commenting out a chunk of code without the linter
demanding ` * ` prefixes (or other comment styling) on each line — use the
shorthand `EXCLUDED CODE` on the opening line. It is an alias for
`sql-lint:disable-block all`:

```sql
/* EXCLUDED CODE
SELECT not_ready_yet(
  foo
  , bar
);
*/
```

Text may follow it (e.g. `/* EXCLUDED CODE — disabled until issue #123`).

### Region suppression (real code, not a comment)

To suppress a chunk of actual code — e.g. borrowed code deliberately left
unreformatted — wrap it in `disable-block <rule|all>` / `enable-block`
directives on their own `--` lines. Unlike the `/* */`-anchored form above,
this pair works outside a comment and is closed explicitly rather than by a
comment's own `*/` (if never closed, it runs to end of file):

```sql
-- sql-lint:disable-block all
SELECT n1.nspname AS fk_schema_name,
       c1.relname AS fk_table_name
  FROM pg_catalog.pg_constraint k1
-- sql-lint:enable-block
```

## Adding New Rules

Add a subroutine to `bin/sql-lint` and register it in the `@rules` array:

```perl
sub check_my_rule {
    my ($file, $lines) = @_;
    my @out;
    for my $l (@$lines) {
        next unless $l->{state} eq 'CODE';
        my $cc = code_content($l->{text});
        next unless $cc =~ /pattern/;
        maybe_finding(\@out, $lines, $file, $l->{lineno}, 'my-rule',
            'description of the violation');
    }
    return @out;
}
```

Each line in `$lines` is a hashref with `lineno`, `state` (`CODE` or
`COMMENT`), and `text`. The `code_content()` helper strips strings,
comments, and `/*` from a line. `maybe_finding()` handles suppression
automatically.

Then add test fixtures and/or inline tests:

- **Fixtures** (`test/fixtures/`): use `.good.sql` for clean files,
  `.bad.sql` for files with violations. Bad fixtures need a
  `-- expect-findings: N` header. No test code changes required.
- **Inline tests** (`test/02-scanner.t`): for specific edge cases,
  regression tests, and assertions about finding content.

## Testing

Tests use Perl's `Test::More` + `prove` to test the linter itself (not
the extension code — that's what `make lint` is for):

```bash
make -C lint test         # all linters (currently just sql)
make -C lint/sql test     # sql linter only
```

## Design

See [DESIGN.md](DESIGN.md) for architecture decisions and rationale.

## Future

The `lint/` directory is designed to host linters for other languages
(e.g. PL/pgSQL, bash). Each would be a sibling to `sql/` with its own
`Makefile` and test suite.
