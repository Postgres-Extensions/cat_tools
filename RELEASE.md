# Releasing cat_tools

See [`../ai/RELEASE.md`](../ai/RELEASE.md) for the actual release process.
What follows is repo-specific context that doesn't belong in that shared
doc.

## Pre-0.2.2 releases predate tagging

cat_tools' first git tag is `0.2.2`; `0.1.0`/`0.1.3`/`0.1.4`/`0.1.5`, `0.2.0`,
and `0.2.1` were never tagged. The shared doc's step 1 (verify committed
version files haven't drifted) calls for comparing a version file's
last-touching commit against that version's tag — there's no tag to compare
against for any of those versions. See CLAUDE.md "SQL file conventions" for
how those pre-0.2.0 versions are tracked (plain `.sql`, no `.sql.in`).

## 0.2.3 catalog-view repair / `pg_upgrade` caveat

Databases updated from 0.2.0/0.2.1 hold broken catalog views that fail
binary `pg_upgrade` to PostgreSQL 12+ until the extension is updated to
0.2.3 (the update rebuilds them, dropping and recreating the public
`pg_class_v`/`column`/`pg_class()` objects without `CASCADE`). Surface this
in the release notes when people may cross the PG 11 → 12+ boundary. See
README.asc "Updating the extension" and
https://github.com/Postgres-Extensions/cat_tools/pull/42.
