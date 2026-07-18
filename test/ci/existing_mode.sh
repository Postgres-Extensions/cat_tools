#!/usr/bin/env bash
#
# Shared CI helper for exercising the cat_tools test suite against a REAL
# database whose extension was installed/updated/pg_upgraded OUTSIDE the suite
# ("existing" mode). Both the pg-upgrade legs and the extension-update scenarios
# in .github/workflows/ci.yml repeat the same sequence:
#
#   install -> plant dependency guard -> update/upgrade -> assert version
#            -> run the suite in existing mode
#
# so it lives here once instead of being duplicated as inline YAML. Run from the
# repository root (where make works); psql/createdb connect via the standard
# PG* environment the CI job already sets.
#
# Why the dependency guard: "existing" mode must run the suite against the ACTUAL
# upgraded/updated objects. If anything silently dropped + reinstalled the
# extension, the suite would test a FRESH install and hide a regression. As
# belt-and-suspenders to the load.sql guarantee (existing mode never drops the
# extension), we plant an object that HARD-references a cat_tools member so a
# non-CASCADE DROP EXTENSION fails, and we actively PROVE that here (see
# plant_guard): if the drop unexpectedly succeeds, this script fails CI.
#
# See https://github.com/Postgres-Extensions/cat_tools/pull/16 for context.
set -euo pipefail

# A view whose output column has a cat_tools enum type creates a pg_depend edge
# to that extension member, so a non-CASCADE DROP EXTENSION cannot succeed. The
# enum is only ever extended (ALTER TYPE ... ADD VALUE) by the update scripts,
# never dropped, so the guard survives 0.2.2 -> current updates and binary
# pg_upgrade.
GUARD_SCHEMA=cat_tools_drop_guard
GUARD_VIEW=guard

current_version() {
  make -s print-PGXNVERSION 2>/dev/null | sed -n 's/.*set to "\(.*\)"$/\1/p'
}

installed_version() {
  psql -d "$1" -tAc \
    "SELECT extversion FROM pg_extension WHERE extname = 'cat_tools'"
}

guard_present() {
  test "$(psql -d "$1" -tAc \
    "SELECT count(*) FROM pg_views WHERE schemaname = '$GUARD_SCHEMA' AND viewname = '$GUARD_VIEW'")" = 1
}

# Plant the guard and PROVE it blocks a non-CASCADE drop. Call right after
# CREATE EXTENSION (and before any update/upgrade) so it persists through them.
plant_guard() {
  local db=$1
  psql -d "$db" -v ON_ERROR_STOP=1 <<SQL
CREATE SCHEMA IF NOT EXISTS $GUARD_SCHEMA;
CREATE OR REPLACE VIEW $GUARD_SCHEMA.$GUARD_VIEW AS
  SELECT NULL::cat_tools.relation_type AS guarded_member;
SQL
  assert_drop_blocked "$db"
}

# The core safeguard self-check: a non-CASCADE DROP EXTENSION MUST fail while the
# guard exists. If it succeeds, the guard is ineffective and existing mode could
# silently test a fresh install -- fail loudly so CI never passes unprotected.
assert_drop_blocked() {
  local db=$1
  if psql -d "$db" -v ON_ERROR_STOP=1 -c "DROP EXTENSION cat_tools" >/dev/null 2>&1; then
    echo "FAIL: DROP EXTENSION cat_tools (non-CASCADE) unexpectedly SUCCEEDED in '$db' -- dependency guard is ineffective" >&2
    exit 1
  fi
  guard_present "$db" \
    || { echo "FAIL: dependency guard missing from '$db' after the drop attempt" >&2; exit 1; }
  test -n "$(installed_version "$db")" \
    || { echo "FAIL: cat_tools extension missing from '$db' after the drop attempt" >&2; exit 1; }
  echo "OK: non-CASCADE DROP EXTENSION is blocked in '$db' (dependency guard effective)"
}

assert_version() {
  local db=$1 expected=$2 installed
  [ "$expected" = current ] && expected=$(current_version)
  installed=$(installed_version "$db")
  echo "version check '$db': installed='$installed' expected='$expected'"
  if [ -z "$installed" ] || [ -z "$expected" ] || [ "$installed" != "$expected" ]; then
    echo "FAIL: cat_tools in '$db' is '$installed', expected '$expected'" >&2
    exit 1
  fi
}

update_ext() {
  local db=$1 to=${2:-}
  if [ -n "$to" ]; then
    psql -d "$db" -v ON_ERROR_STOP=1 -c "ALTER EXTENSION cat_tools UPDATE TO '$to'"
  else
    psql -d "$db" -v ON_ERROR_STOP=1 -c "ALTER EXTENSION cat_tools UPDATE"
  fi
}

# Run the pgTAP suite against an already-populated database in existing mode.
# Verifies the extension is at the current version, re-proves the guard still
# blocks a drop (i.e. it survived the update/upgrade), runs the suite via
# --use-existing so pg_regress does NOT drop/recreate the database, then confirms
# the guard is still present (a CASCADE drop+reinstall would have removed it).
run_suite() {
  local db=$1
  assert_version "$db" current
  assert_drop_blocked "$db"
  make check-relkind-source
  # In existing mode pg_regress runs against $db via --use-existing and must NOT
  # create/drop its own database. Two consequences drive the make args below:
  #   1. PGXNTOOL_ENABLE_TEST_BUILD=no: base.mk auto-enables the test-build sanity
  #      check whenever test/build/*.sql exist, adding it as a `test` prerequisite.
  #      test-build spawns a recursive `installcheck` that INHERITS this call's
  #      --use-existing (a command-line var propagates to sub-makes) but targets a
  #      fresh `regression` DB it cannot create under --use-existing, so it dies
  #      with "database regression does not exist". test-build is a fresh-install
  #      check already run by the fresh `test` job on every PG version, so it adds
  #      nothing here -- disable it.
  #   2. verify-results depends on `test`, so it re-runs the suite; it must carry
  #      the SAME existing-mode overrides or it would re-run FRESH (against a new
  #      regression DB) instead of verifying THIS existing database.
  local existing_args="TEST_LOAD_SOURCE=existing CONTRIB_TESTDB=$db EXTRA_REGRESS_OPTS=--use-existing PGXNTOOL_ENABLE_TEST_BUILD=no"
  make test $existing_args
  make verify-results $existing_args
  guard_present "$db" \
    || { echo "FAIL: dependency guard vanished during the suite run on '$db' -- extension was dropped+reinstalled (CASCADE)?" >&2; exit 1; }
}

cmd=${1:-}
shift || true
case "$cmd" in
  plant-guard)
    # plant-guard DB   (extension must already be installed, >= 0.2.2)
    plant_guard "$1"
    ;;
  update)
    # update DB [TO_VERSION]   (empty TO_VERSION => update to current)
    update_ext "$1" "${2:-}"
    ;;
  prepare-old)
    # prepare-old DB INSTALL_VERSION [BRIDGE_TO]
    #   Old-cluster preparation for pg-upgrade-test. Create the database and the
    #   extension at INSTALL_VERSION; if BRIDGE_TO is given, ALTER EXTENSION
    #   UPDATE TO it first. That "bridge" models the real migration path a user
    #   on an OLD PostgreSQL + OLD cat_tools must take: e.g. on PG10, install
    #   0.2.0 then update to 0.2.2 BEFORE pg_upgrade, because the 0.2.0->0.2.2
    #   script recreates the views with the pg_upgrade-safe omit_column fix
    #   (https://github.com/Postgres-Extensions/cat_tools/pull/18) -- the raw
    #   0.2.0 views reference catalog columns removed in newer PostgreSQL and
    #   would break binary pg_upgrade. Then plant + prove the dependency guard
    #   (at the bridged version, so cat_tools.relation_type exists).
    db=$1 install=$2 bridge=${3:-}
    createdb "$db"
    psql -d "$db" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION cat_tools VERSION '$install'"
    # Use `if`, not `&&`: under `set -e` a false `[ -n ... ] && ...` would abort.
    if [ -n "$bridge" ]; then update_ext "$db" "$bridge"; fi
    plant_guard "$db"
    ;;
  run-suite)
    # run-suite DB   (extension must already be at the current version)
    run_suite "$1"
    ;;
  update-scenario)
    # update-scenario DB FROM_VERSION
    #   Full extension-update flow that runs the existing-mode suite: create the
    #   DB and extension at FROM_VERSION, plant + prove the guard, update to the
    #   current version, then run the suite against that real updated database.
    db=$1 from=$2
    createdb "$db"
    psql -d "$db" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION cat_tools VERSION '$from'"
    plant_guard "$db"
    update_ext "$db"
    run_suite "$db"
    ;;
  update-check)
    # update-check DB FROM_VERSION TO_VERSION
    #   Lightweight check that a specific update script applies (no suite): used
    #   for the pre-0.2.2 scripts, which only install on PG10 and target 0.2.2
    #   (not the current version, so the suite cannot run against them).
    db=$1 from=$2 to=$3
    createdb "$db"
    psql -d "$db" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION cat_tools VERSION '$from'"
    update_ext "$db" "$to"
    assert_version "$db" "$to"
    ;;
  *)
    echo "usage: $0 {plant-guard|update|prepare-old|run-suite|update-scenario|update-check} ..." >&2
    exit 2
    ;;
esac
