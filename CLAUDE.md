# Claude Code Instructions for cat_tools

## GitHub CI

After **every** push, monitor GitHub CI in a background subagent until all jobs pass or a failure is confirmed. Use `gh pr checks <pr> --watch` when the branch has an open PR; otherwise (a branch with no PR yet, or a push to `master`) use `gh run watch` for the pushed commit. Investigate and fix failures immediately rather than leaving them for the user to notice.

(`paths-ignore` in `.github/workflows/ci.yml` skips CI only when the *entire* change set is docs-only — e.g. a docs-only push to `master`, or a PR whose whole diff is `**.md`/`**.asc`. A docs-only commit on a PR that also touches code still triggers CI on the full PR diff. When unsure, check `gh run list` for the pushed commit and monitor whatever run appears; if none does, there is nothing to watch.)

## Bug Fixes

When fixing a bug, add a comment at the fix site explaining what the bug was and why the fix works. The goal is to prevent re-introducing the bug later.

## Git

**Never delete a branch without explicit user approval.** This includes `git push origin --delete`, `git branch -d`, and `git branch -D`. Always ask first.

**Always open PRs against the main repo** (`Postgres-Extensions/cat_tools`), not a fork.

## Terminology

- **Extension update**: moving from one cat_tools version to another (e.g. `ALTER EXTENSION cat_tools UPDATE`). Always say "update" for this.
- **PostgreSQL upgrade**: upgrading a PostgreSQL cluster to a newer major version (e.g. `pg_upgrade`, `pg_upgradecluster`). Always say "upgrade" for this.

Never use "upgrade" to describe an extension version change, and never use "update" to describe a PostgreSQL cluster version change.

## SQL file conventions

Rules for what to track in git:

0. If a `.sql.in` file exists, track the `.sql.in` and **not** the corresponding `.sql`.
1. If no `.sql.in` exists, track the `.sql` directly (e.g. historical pre-0.2.0 files).
2. Version-specific install scripts (e.g. `sql/cat_tools--0.2.2.sql.in`) MUST be tracked.
3. Update scripts (e.g. `sql/cat_tools--0.2.1--0.2.2.sql.in`) MUST be tracked.
4. The current version'''s install script (e.g. `sql/cat_tools--0.2.2.sql.in`) is generated
   by `make` from `sql/cat_tools.sql.in`, but MUST still be tracked (rule 2 applies).
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

The `extension-update-test` job exercises the widest update path we can — install the
oldest cat_tools version that still installs on the supported PostgreSQL range and update
to the current version — on the full `pg: [12..18]` matrix. It runs the pgTAP suite in
upgrade mode (`make test TEST_LOAD_SOURCE=upgrade`, backed by the committed-once
`test/install/load.sql`), so a broken or incomplete update makes the suite fail. `0.2.2` is
the starting floor only for backward-compat: the 0.2.0/0.2.1 (and earlier) install scripts
fail on PG11+/PG12+, so they cannot be the starting point. PG12 is the PostgreSQL floor —
PG11 (and PG10) cannot run `ALTER TYPE ... ADD VALUE` in extension update scripts; this
restriction was lifted in PG12. There is no upper bound.

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
