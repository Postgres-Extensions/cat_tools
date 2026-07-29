# CI Instructions

## Reducing CI wall-clock time

Don't chase this proactively -- it's not worth adding real complexity for. But if a *simple*
latency win is available while touching a job anyway, take it. Facts and constraints to reason
from:

- **GitHub Actions steps within one job are strictly sequential.** There is no native
  "run step A and step B concurrently" mechanism. The only real unit of parallelism is the
  *job* (already exploited here via the `pg`/matrix-leg lists) -- reordering two independent
  steps changes nothing about total wall-clock time unless one of them is actually
  backgrounded (`cmd &` ... `wait`) within a single step's shell script.
- **`pg-start VERSION` is not a no-op or a "wait for something already running."** It installs
  that PostgreSQL major version via `apt.postgresql.org.sh` (network + package install) and
  then creates and starts the "test" cluster (`pg_createcluster --start`) -- both genuinely
  slow, and both block until done, like every `run:` step.
- **Backgrounding a step next to `pg-start` (or any `apt-get install`) is NOT safe by
  default**: apt/dpkg serialize on a lock file, so a second concurrent `apt-get install` would
  either fail immediately or block waiting for the lock -- effectively serializing anyway, but
  now with added flakiness risk. Only background work that doesn't touch the package manager
  (e.g. a `git clone`, or a build step that's pure `gmake`/`gcc` against already-installed
  headers) alongside an apt-based step.
- **A genuine, low-complexity candidate, if this is ever worth doing**: `pg-tle-test`'s
  "Install pgtap" step (`make pgtap`, which builds pgTAP via `gmake`/`gcc`, not apt) and its
  "Build and install pg_tle" step (`git clone` + `make`, also not apt) are mutually
  independent -- neither depends on the other's output. Backgrounding one (`make pgtap &`)
  while the other runs, then `wait`ing for it before the step that needs pgtap, would overlap
  two of the job's slower operations. This is a small, contained change (one background job,
  one `wait`, one exit-code check) -- not the kind of complexity worth avoiding on principle.
- **`actions/cache` is likely a better lever than backgrounding.** pg_tle is rebuilt from
  source (git clone + C compile) fresh in every `pg-tle-test` matrix entry and on both the old
  and new cluster in every `pg-tle-upgrade-test` leg -- the same pg_tle version, rebuilt
  repeatedly across runs with nothing changed. Caching the built `pg_tle.so` + control/SQL
  files (keyed on PG major version + `PG_TLE_RELEASE`) would skip the clone+compile entirely on
  a cache hit, without touching the job's logic at all. Worth trying before hand-rolled
  parallelism if CI time on the pg_tle jobs becomes a real pain point.
- **Double-run check**: this repo's `push:` trigger is scoped to `branches: [master]` (not a
  bare `on: [push, pull_request]`), so pushes to a feature/PR branch only fire the
  `pull_request` event, not both -- confirmed via run history, no double-run here. If this
  workflow's triggers are ever changed, re-verify that scoping is preserved; an unscoped
  `push:` trigger would double-run CI on every PR-branch commit.

## Docs-only pushes and "what was actually tested"

A docs-only push makes the heavy jobs report "skipped" for THAT commit, which is correct (the
code didn't change) but easy to misread on the PR's Checks tab as "never tested." The `changes`
job's "Find the last commit where real code changed" step handles this: it walks backward
through history to the newest commit that actually changed code, looks up that commit's CI run,
and `all-checks-passed` reports it (link + green/red) in its step summary -- or explicitly notes
when the entire PR has never touched anything but docs. Don't assume "skipped" means "untested"
without checking that summary first.

## `pull_request_target` workflows can't be tested from the PR that changes them

GitHub always executes the workflow FILE for a `pull_request_target` event from the BASE
branch (master), never the PR's own version -- a deliberate security control so a fork PR can't
alter its own reviewer's permissions/behavior. `claude-code-review.yml` runs this way. Practical
consequence: a PR that changes that file (e.g. adjusting its `permissions:` block) cannot prove
the change took effect by watching that PR's own `claude-review` check -- it's still running
master's old version. Verify changes to that file only after merging to master, on the next PR.

## Where CI-only shell logic lives

`.github/scripts/` holds shell scripts that are **only** meaningful inside a CI job (e.g.
`pg_upgrade_cluster`, which drives `pg_ctlcluster`/`pg_createcluster`/`pg_upgrade` against the
pgxn-tools image's "test" cluster convention -- not something a developer would run locally).
This is distinct from the repo-root `bin/` scripts (`bin/test_existing`, `bin/assert_fs_clean`),
which a developer CAN run locally against a scratch database and are also usable outside CI.
When adding a new shared CI shell helper, put it in `.github/scripts/` if it's CI-only, `bin/`
if it's usable locally too.
