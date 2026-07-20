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

## Pull request descriptions

The maintainer builds the squash commit message from the PR description, so the
**opening** of the description is used directly as the basis for that commit message.
Write it accordingly:

- Make the opening stand alone as a good commit message: no leading header/title line
  (the PR title is the subject), concise, self-contained. Multiple paragraphs are fine.
- Lead with the substantive change and why. Keep incidental changes (minor doc tweaks,
  dependency/action version bumps, small cleanups) OUT of the opening — put them lower
  or omit them; the diff carries those details for anyone who wants them.
- Do NOT add a marker delimiting the "commit message" from "the rest". Just let the
  opening carry its own weight, with any extra context following after it.
- Do NOT hard-wrap paragraphs: write each paragraph as a single long line (blank line
  between paragraphs). Hard-wrapping at ~80 columns conflicts with how GitHub builds the
  squash commit message from the description.

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
4. EXCEPTION to rule 2: a version that changes little AND ships no nontrivial update-path machinery MAY omit its generated install script (little test-coverage value; it is regenerated from `sql/cat_tools.sql.in` at build time). Track it whenever the version carries meaningful changes or a nontrivial update script — a complex update warrants the committed install script for update-test coverage and provenance.
5. Version-specific files MUST NEVER be edited manually — always edit `sql/cat_tools.sql.in`
   and regenerate.

## CI: extension-update-test matrix

The `extension-update-test` job in `.github/workflows/ci.yml` is currently restricted to
`pg: [10]` because that is the only PostgreSQL version where the pre-0.2.2 install scripts
install cleanly:
- PG 11 added `attmissingval` (pseudo-type `anyarray`) to `pg_attribute`; the old `SELECT *`
  in `0.2.0`/`0.2.1` tries to include it directly, failing with "column attmissingval has
  pseudo-type anyarray".
- PG 12+ exposed the `oid` system column in `SELECT *`, breaking `0.2.0`/`0.2.1` with
  "column oid specified more than once".

**When working on a new version:** review and expand this matrix. The new version's install
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
