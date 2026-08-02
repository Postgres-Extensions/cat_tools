# Claude Code Instructions for cat_tools

## GitHub CI

After **every** push, monitor GitHub CI in a background subagent until all jobs pass or a failure is confirmed. Use `gh pr checks <pr> --watch` when the branch has an open PR; otherwise (a branch with no PR yet, or a push to `master`) use `gh run watch` for the pushed commit. Investigate and fix failures immediately rather than leaving them for the user to notice.

(`.github/workflows/ci.yml`'s `changes` job computes the actual per-push changed file set and exposes `docs_only`; the heavy `test`, `pg-upgrade-test`, and `extension-update-test` jobs skip when `needs.changes.outputs.docs_only == 'true'` — i.e. every changed file in that push matches `**.md`/`**.asc`. Unlike the old workflow-level `paths-ignore`, this is evaluated per push/commit, not over the whole PR diff, so a doc-only commit on a PR that also touches code still gets the skip, and the workflow (including the required `all-checks-passed` check) always triggers and reports rather than being skipped outright by GitHub. When unsure, check `gh run list` for the pushed commit and monitor whatever run appears; if none does, there is nothing to watch.)

## Build/test system (pgxntool)

This repo's build is driven by pgxntool (embedded under `pgxntool/`). Its docs are
**not** auto-loaded, so for any non-trivial build or test work, read `pgxntool/README.asc`
and `pgxntool/CLAUDE.md` first. High-value gotchas that those docs explain:

- `DATA`, `MODULES`, `DOCS`, and `installcheck` are PGXS variables/targets, not
  pgxntool's; pgxntool only wraps/seeds them. Don't assume they belong to pgxntool.
- `make test` returns non-zero on test regressions (pgxntool 2.3.0+): `installcheck`
  itself is still marked `.IGNORE`, but `test`'s own recipe now checks
  `test/regression.diffs` and exits non-zero if it's non-empty. `make verify-results`
  remains the stricter, documented CI gate: it depends on `$(TEST_DEPS)` directly, not
  on `test` itself (deliberately — `test`'s own early exit would otherwise abort the
  chain before verify-results got to inspect and report the diff), and applies a
  stricter pgtap-aware check on top. A bare `make test` failing locally is now a real
  signal too, just not the documented gate.
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

**Prefix with `CI: `** any commit/PR subject whose change affects ONLY CI (workflow files,
CI-only scripts) and does not touch the main test suite/build. A change that also touches the
test suite/build does not get the prefix, even if CI-related.

## References to PRs and issues in committed files

A reference to a GitHub PR or issue inside a **committed file** (SQL/code comments,
`.github/workflows/ci.yml` comments, `CLAUDE.md`, `test/install/load.sql`, docs) MUST be a
full URL, e.g. `https://github.com/Postgres-Extensions/cat_tools/issues/28` — never a bare
`#28` (a bare number is meaningless when the file is read outside GitHub), **if it's
something a reader might still need to act on or look up** — an open TODO, a workaround to
revisit once some other issue lands, a known limitation. For a reference that's purely
historical context (explaining why past code looks the way it does, where the issue is
already resolved and there's nothing left to do), a bare `#28` is fine — readers are less
likely to need to chase it down, and it's less noise. When in doubt, use the full URL.
Referencing by number is always fine in GitHub-native text (PR/issue titles and
descriptions, review comments).

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
  in `existing` mode. Two shapes:
  - `old_pg>=11`: install `0.2.2` directly → plant guard → pg_upgrade → update to current.
    A *fresh* `0.2.2` install builds the views with the pg_upgrade-safe `omit_column` (`!= ALL`),
    so it survives pg_upgrade as-is.
  - `old_pg=10`: the FULL real-world journey — install `0.2.0`, **bridge-update to `0.2.3` on
    the old cluster** → plant guard → pg_upgrade → update to current. The bridge must reach
    `0.2.3`, not `0.2.2`: the shipped `0.2.0`→`0.2.2` / `0.2.1`→`0.2.2` scripts do NOT fix the
    views (their `omit_column` used the no-op `!= ANY`, leaving `relhasoids`/`relhaspkey` in
    `_cat_tools.pg_class_v`); the pg_class_v DROP+CREATE rebuild that strips those columns lives
    in the `0.2.2`→`0.2.3` update. `0.2.3` is also the furthest a PG10 cluster can reach
    (`0.2.3`→`0.3.0` uses `ALTER TYPE ... ADD VALUE`, unrunnable in an update script before
    PG12); the post-upgrade step then updates `0.2.3`→current on the new cluster. This proves a
    `0.2.3` reached via the bridge update (not a fresh install) survives pg_upgrade.
  Both flows plant the dependency guard and run through `bin/test_existing`.

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

### Closing non-indentable blocks
When closing a code block that cannot be indented to show its nesting (e.g. SQL
`\endif`, `DO $$...$$`, shell heredocs, column-0 `fi`/`esac`) AND that block
contains nested blocks, label the closer with a comment naming which block it
closes — e.g. shell `esac  # basename dispatch`, or a named dollar-quote
`DO $DO$ ... $DO$` for a DO block. Where the language rejects a trailing comment
on the closer (psql `\endif` warns "extra argument ignored"), put the label on
the immediately following line instead (e.g. `\endif` then
`-- end \if :cat_tools_mode_existing`).

### Terminology
"upgrade" refers to a PostgreSQL cluster (`pg_upgrade`); "update" refers to an extension
(`ALTER EXTENSION ... UPDATE`). cat_tools' version-to-version scripts are "update scripts" —
never "upgrade scripts."
