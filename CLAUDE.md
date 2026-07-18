# Claude Code Instructions for cat_tools

## GitHub CI

After **every** push, monitor GitHub CI in a background subagent until all jobs pass or a failure is confirmed. Use `gh pr checks <pr> --watch` when the branch has an open PR; otherwise (a branch with no PR yet, or a push to `master`) use `gh run watch` for the pushed commit. Investigate and fix failures immediately rather than leaving them for the user to notice.

(`paths-ignore` in `.github/workflows/ci.yml` skips CI only when the *entire* change set is docs-only — e.g. a docs-only push to `master`, or a PR whose whole diff is `**.md`/`**.asc`. A docs-only commit on a PR that also touches code still triggers CI on the full PR diff. When unsure, check `gh run list` for the pushed commit and monitor whatever run appears; if none does, there is nothing to watch.)

## Build/test system (pgxntool)

This repo's build is driven by pgxntool (embedded under `pgxntool/`). Its docs are
**not** auto-loaded, so for any non-trivial build or test work, read `pgxntool/README.asc`
and `pgxntool/CLAUDE.md` first. High-value gotchas that those docs explain:

- `DATA`, `MODULES`, `DOCS`, and `installcheck` are PGXS variables/targets, not
  pgxntool's; pgxntool only wraps/seeds them. Don't assume they belong to pgxntool.
- `make test` does **not** return non-zero on test regressions — pgxntool marks
  `installcheck` as `.IGNORE`. To actually detect failures, use `make verify-results`
  (or inspect `test/regression.diffs`). This is why CI must gate on `verify-results`.
- `test/install/*.sql` runs once, committed, before the suite in the same `pg_regress`
  invocation, so its state persists into every test. `test/build/*.sql` are separate
  build sanity checks run before the suite.
- Versioned `.sql` files are generated from their `.sql.in` sources and gitignored.
  Anything referencing them at Make parse time is subject to two-phase-make timing.

## Bug Fixes

Comment the fix where it isn't self-evident, but keep it concise — no novels. Do NOT
recount the bug's history (what a past version got wrong) UNLESS the same mistake could
realistically be made again; if it could, briefly state the guard fact that prevents it.
Never repeat the same comment verbatim in adjacent code — write it once and reference it
("same as above").

## Git

**Never delete a branch without explicit user approval.** This includes `git push origin --delete`, `git branch -d`, and `git branch -D`. Always ask first.

**Always open PRs against the main repo** (`Postgres-Extensions/cat_tools`), not a fork.

## References to PRs and issues in committed files

Any reference to a GitHub PR or issue inside a **committed file** (SQL/code comments,
`.github/workflows/ci.yml` comments, `CLAUDE.md`, `test/install/load.sql`, docs) MUST be a
full URL, e.g. `https://github.com/Postgres-Extensions/cat_tools/issues/28` — never a bare
`#28` (a bare number is meaningless when the file is read outside GitHub). Referencing by
number is fine only in GitHub-native text (PR/issue titles and descriptions, review
comments).

## SQL file conventions

Rules for what to track in git:

0. If a `.sql.in` file exists, track the `.sql.in` and **not** the corresponding `.sql`.
1. If no `.sql.in` exists, track the `.sql` directly (e.g. historical pre-0.2.0 files).
2. Version-specific install scripts (e.g. `sql/cat_tools--0.2.2.sql.in`) are tracked BY
   DEFAULT. They enable update testing (install an old version, `ALTER EXTENSION UPDATE`,
   verify) and, because a new MAJOR PostgreSQL version can unpredictably break installing
   an OLDER extension version, keeping old versions committed lets CI catch when a version
   stops installing on a newer PG.
   See https://github.com/Postgres-Extensions/pgxntool/issues/51.
3. Update scripts (e.g. `sql/cat_tools--0.2.1--0.2.2.sql.in`) MUST be tracked — they are
   essential to the update path and have no substitute.
4. EXCEPTION to rule 2: a minor version that doesn't significantly change the extension
   (e.g. a small bug fix) is unlikely to cross a PG supported-version boundary, so its
   generated install script adds little test-coverage value and MAY be omitted (regenerated
   from `sql/cat_tools.sql.in` at build time). 0.2.3 is such a case — which is why
   `sql/cat_tools--0.2.3.sql.in` is intentionally NOT tracked.
5. Version-specific files MUST NEVER be edited manually — always edit `sql/cat_tools.sql.in`
   and regenerate.

## CI: PostgreSQL version support

**Policy:** Never support a fresh install on any PostgreSQL version where the extension
update path is known to be broken — a version that cannot be updated to is not truly
supported.

Both PG10 and PG11 are dropped as of 0.3.0. The `ALTER TYPE ... ADD VALUE` statements in
the update script cannot run inside an extension update script on PG11 or earlier
(PROCESS_UTILITY_QUERY context); this restriction was lifted in PG12. Because a version
that cannot be updated to is not truly supported, PG10 and PG11 support is dropped
entirely. cat_tools 0.3.0 supports PG12+.

### Test-load modes (`TEST_LOAD_SOURCE`)

`test/install/load.sql` installs the suite's dependencies once, committed, before the pgTAP
suite. The Makefile exports the mode (and update range) as placeholder GUCs via `PGOPTIONS`;
`TEST_LOAD_SOURCE` must be `fresh`, `update`, or `existing` (anything else is a hard
parse-time error):

- **fresh** (default): `CREATE EXTENSION cat_tools` at the current version.
- **update**: `CREATE EXTENSION` at `TEST_UPDATE_FROM` (default `0.2.2`) then
  `ALTER EXTENSION cat_tools UPDATE` — to `TEST_UPDATE_TO` if set, else to the current
  version. Running the SAME suite/expected output asserts an updated database behaves
  identically to a fresh install. `make test-update` is the shorthand.
- **existing**: the extension is ALREADY installed (by binary `pg_upgrade`, or an
  `ALTER EXTENSION UPDATE` performed outside the suite). load.sql does not touch it; it only
  asserts presence + current version and creates the test roles. Pair with
  `CONTRIB_TESTDB=<db> EXTRA_REGRESS_OPTS=--use-existing` so `pg_regress` runs against that
  database instead of dropping/recreating a throwaway one.

### CI jobs

- `extension-update-test` exercises the widest update path we support — `0.2.2` → current
  in `update` mode — on `pg: [12..18]`, plus a PG10-only leg that exercises the pre-0.2.2
  update scripts (`0.2.0`→`0.2.2` and `0.2.1`→`0.2.2`, which install only on PG10 and target
  `0.2.2`, not the current version). `0.2.2` is the update-from floor only for backward-compat:
  the 0.2.0/0.2.1 install scripts fail on PG11+/PG12+. PG12 is the PostgreSQL floor — PG11 and
  earlier cannot run `ALTER TYPE ... ADD VALUE` in extension update scripts (lifted in PG12).
- `pg-upgrade-test` binary-`pg_upgrade`s a real database and then runs the suite against it
  in `existing` mode (`0.2.2` is the oldest version that survives pg_upgrade — pre-0.2.2
  views reference catalog columns removed in newer PostgreSQL). Two shapes:
  - `old_pg>=11`: install `0.2.2` directly → plant guard → pg_upgrade → update to current.
  - `old_pg=10`: the FULL real-world journey — install `0.2.0`, **bridge-update to `0.2.2` on
    the old cluster** (the `0.2.0`→`0.2.2` script recreates the views with the pg_upgrade-safe
    omit_column fix) → plant guard → pg_upgrade → update to current. This proves a `0.2.2`
    reached via the bridge update (not a fresh install) survives pg_upgrade.
  Both flows plant the dependency guard and run through `test/ci/existing_mode.sh`.

**When working on a new version:** review and expand these matrices. A new version's install
script may support more PG versions, enabling testing of the update path from older
cat_tools versions on newer PostgreSQL.

## Code Style

### Comments
Always use block comment format for multi-line comments in SQL files:

```sql
/*
 * First line of comment.
 * Second line of comment.
 */
```

Never use `--` line comments for multi-line explanations.

### Terminology
"upgrade" refers to a PostgreSQL cluster (`pg_upgrade`); "update" refers to an extension
(`ALTER EXTENSION ... UPDATE`). cat_tools' version-to-version scripts are "update scripts" —
never "upgrade scripts."
