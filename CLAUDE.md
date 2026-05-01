# Claude Code Instructions for cat_tools

## GitHub CI

After pushing to a branch with an open PR, monitor CI using `gh pr checks --watch` in a background subagent until all jobs pass or a failure is confirmed. Investigate and fix failures immediately rather than leaving them for the user to notice.

## Bug Fixes

When fixing a bug, add a comment at the fix site explaining what the bug was and why the fix works. The goal is to prevent re-introducing the bug later.

## Git

**Never delete a branch without explicit user approval.** This includes `git push origin --delete`, `git branch -d`, and `git branch -D`. Always ask first.

**Always open PRs against the main repo** (`Postgres-Extensions/cat_tools`), not a fork.

## SQL file conventions

Rules for what to track in git:

0. If a `.sql.in` file exists, track the `.sql.in` and **not** the corresponding `.sql`.
1. If no `.sql.in` exists, track the `.sql` directly (e.g. historical pre-0.2.0 files).
2. Version-specific install scripts (e.g. `sql/cat_tools--0.2.2.sql.in`) MUST be tracked.
3. Upgrade scripts (e.g. `sql/cat_tools--0.2.1--0.2.2.sql.in`) MUST be tracked.
4. The current version'''s install script (e.g. `sql/cat_tools--0.2.2.sql.in`) is generated
   by `make` from `sql/cat_tools.sql.in`, but MUST still be tracked (rule 2 applies).
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
script may support more PG versions, enabling testing of the upgrade path from older
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
