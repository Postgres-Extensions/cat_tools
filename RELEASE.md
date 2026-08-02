# Releasing cat_tools

cat_tools builds on pgxntool (https://github.com/Postgres-Extensions/pgxntool);
the release machinery (`make tag`, `make dist`) lives in `pgxntool/base.mk`. These
steps cut a new release.

## 1. Safety check: verify committed version files haven't drifted

Before anything else, confirm every committed versioned install script still matches
what that version actually shipped.

- [ ] For each committed versioned install script — `sql/cat_tools--<version>.sql.in`
      (0.2.0 onward) or `sql/cat_tools--<version>.sql` (the historical pre-0.2.0 files
      `0.1.0`/`0.1.3`/`0.1.4`/`0.1.5`, which have no `.sql.in` source and are tracked
      directly; see CLAUDE.md "SQL file conventions") — find its last-touching commit:
      `git log -1 --format='%H %ad' -- sql/cat_tools--<version>.sql.in` (or `.sql`).
- [ ] Confirm that commit is no later than when that version was actually tagged.
      cat_tools tags every release, unprefixed (e.g. `0.2.2`, `0.2.3` — see step 6's
      `make tag`), so compare directly: `git log -1 --format='%H %ad' <version>`. (No
      tags exist before `0.2.2` — `0.1.x`, `0.2.0`, and `0.2.1` predate cat_tools'
      tagging convention — so this direct comparison is only available from `0.2.2`
      onward.)
- [ ] A version file touched by a commit LATER than its own release's tag is a red
      flag — it likely means `default_version` in `cat_tools.control` was left pointing
      at that real (non-`stable`) version after release, and a later source edit to
      `sql/cat_tools.sql.in` silently regenerated — and corrupted — the committed file
      via `sql.mk`'s current-version rule (`$(EXTENSION__CURRENT_VERSION__FILES:.sql=.sql.in):
      sql/cat_tools.sql.in cat_tools.control`, which `cp`s the base source over it).
      Investigate before proceeding.
- [ ] **Known exception, not necessarily a corruption:** a version file whose
      last-touching commit is much later than its version's real release can also mean
      the file was legitimately backfilled or reformatted after the fact (e.g. once new
      build tooling started requiring something that wasn't tracked before). A late
      touch-date alone isn't suspicious — only worry about a file whose *content*
      actually differs from what shipped.

## 2. Pre-release checks
- [ ] Open issues/PRs for this release reviewed, merged or deferred.
- [ ] CI green on all supported PostgreSQL versions (the `all-checks-passed` job on master).
- [ ] Locally: `make verify-results` passes. It depends on `$(TEST_DEPS)` directly, not
      on `test` itself (deliberately — see `base.mk`'s own comment on why: `test`'s early
      exit on a regression would otherwise abort the chain before verify-results got to
      inspect and report the diff), so it still runs the suite first, then gates on the
      results with a stricter pgtap-aware check. `make test` itself also returns
      non-zero on a regression as of pgxntool 2.3.0, but `verify-results` remains the
      stricter, documented gate.

## 3. Decide the version and what to track
- [ ] Pick the new version (semantic versioning).
- [ ] **Minor change? Consider NOT committing the generated versioned install script.**
      If this release makes only fairly minor changes (unlikely to cross a PostgreSQL
      supported-version boundary), decide whether to omit the generated
      `sql/cat_tools--<version>.sql.in` — it has little update-test-coverage value and
      omitting it keeps the repo smaller (it is regenerated from `sql/cat_tools.sql.in`
      at build time). The update script (`sql/cat_tools--<prev>--<version>.sql.in`) is
      ALWAYS committed. See CLAUDE.md "SQL file conventions".

## 4. Update version + changelog

> **⚠️ CRITICAL — you are temporarily leaving the `stable` pseudo-version.** Master's
> `default_version` normally sits at the `stable` pseudo-version so that source edits
> regenerate `cat_tools--stable.sql` and never a frozen released file. Stamping a real
> version here points the generated current-version file at `cat_tools--<version>`. The
> moment this release is merged you **MUST** flip `default_version` back to `stable` on
> master (step 7). If you forget, the next source edit on master will regenerate — and
> corrupt — the just-released version's install file.

- [ ] Bump `default_version` in `cat_tools.control` (bumped by hand).
- [ ] Bump the version in `META.in.json` — the source of truth is
      `provides.cat_tools.version` (also update the top-level `version`); `META.json`,
      `control.mk`, and `meta.mk` (which feeds `PGXNVERSION`) regenerate via `make`.
- [ ] Advance `release_status` in `META.in.json` as appropriate (unstable → testing →
      stable).
- [ ] Add/finish the update script `sql/cat_tools--<prev>--<version>.sql.in`; confirm
      `ALTER EXTENSION cat_tools UPDATE` from the previous version reaches the new one,
      on multiple PG majors.
- [ ] Stamp `HISTORY.asc`: the top `STABLE` section accumulates user-facing changes as
      PRs land; at release, rename that header to the new version number.

## 5. Verify
- [ ] `make verify-results` green (it runs `test` first, then gates on the results).
- [ ] From a clean checkout (or `git archive` of the tag): `make && make install`
      regenerates and installs cleanly and `CREATE EXTENSION cat_tools;` reports the new
      version — confirms a PGXN consumer can build from the tracked sources alone. (This
      mirrors what `make dist` ships, since it archives the tag: committed files only, so
      any omitted generated install script is regenerated on the consumer's side.)

## 6. Tag and distribute

> **⚠️ Pass `PGXN_REMOTE=<remote>` to every target below if your clone's `origin`
> is a personal fork** (as it typically is for a maintainer working from a fork,
> with the canonical repo configured under some other remote name — check
> `git remote -v` rather than assuming it's called `upstream`). Without it,
> `tag`/`rmtag`/`forcetag`/`dist` push to `origin` by default — silently
> tagging the fork instead of `Postgres-Extensions/cat_tools`. This is exactly
> what happened when the 0.2.3 release tag was first cut and had to be
> re-pointed by hand; pgxntool 2.2.0 added `PGXN_REMOTE` specifically to fix
> this (https://github.com/Postgres-Extensions/pgxntool/issues/53).

- [ ] Commit the release changes; working tree must be clean — `make tag` aborts with
      "Untracked changes!" on a dirty tree.
- [ ] `make tag` — creates a git tag named exactly the version, UNPREFIXED (e.g. `0.2.3`,
      matching the existing `0.2.2` tag; no `v` prefix), taken from `PGXNVERSION`, and
      pushes it to `$(PGXN_REMOTE)` (default `origin`). It is idempotent when the tag
      already points at HEAD, and errors if the tag exists on a different commit. To
      move an existing tag use `make forcetag` (= `make rmtag` then `make tag`);
      `make rmtag` deletes the tag locally and on `$(PGXN_REMOTE)`.
- [ ] `make dist` — depends on `tag` (and builds the HTML docs), then
      `git archive`s the tag into `../cat_tools-<version>.zip` (parent directory).
      Because it archives the tag, only committed files are included. If a `.gitattributes`
      exists it must be committed, or `dist` aborts (git archive only honors
      `export-ignore` for committed files). `make forcedist` = `forcetag` + `dist`.
- [ ] Upload the `../cat_tools-<version>.zip` to PGXN (manual).

## 7. Return master to `stable` (CRITICAL — do not skip)
- [ ] As soon as the release is merged, flip `default_version` back to the `stable`
      pseudo-version on master (`cat_tools.control` + `META.in.json`), open a new top
      `STABLE` section in `HISTORY.asc`, and re-seed a fresh
      `sql/cat_tools--<this-release>--stable.sql.in` update script for the next cycle.
      Leaving master stamped at the real version means the next source edit regenerates
      and corrupts the released version's install file.
- [ ] `rm` any stale generated `sql/cat_tools--<released-version>.sql.in` /
      `cat_tools--<released-version>.sql` left in the tree — once `default_version` is
      `stable`, `make` no longer regenerates them, so they are one-time cleanup.

> The persistent `stable` pseudo-version (a permanent version literally named `stable`,
> with a live `sql/cat_tools--<last-release>--stable.sql.in` update script that every
> source fix targets) decouples fixes from version bumps. The machinery is built into
> `sql.mk`; it lands immediately after the 0.2.3 release, so 0.2.3 itself is the last
> release cut before the scheme exists — steps 4/7 above describe the flow from the
> next release onward.

## Notes and caveats

- **0.2.3 catalog-view repair / `pg_upgrade` caveat.** Databases updated from
  0.2.0/0.2.1 hold broken catalog views that fail binary `pg_upgrade` to PostgreSQL
  12+ until the extension is updated to 0.2.3 (the update rebuilds them, dropping and
  recreating the public `pg_class_v`/`column`/`pg_class()` objects without `CASCADE`).
  Surface this in the release notes when people may cross the PG 11 → 12+ boundary. See
  README.asc "Updating the extension" and
  https://github.com/Postgres-Extensions/cat_tools/pull/42.
