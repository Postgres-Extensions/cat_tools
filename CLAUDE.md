# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Scope of This File

The guidance in this CLAUDE.md applies to pgxntool's own source files and provides
recommended best practices for projects using pgxntool. However, any agent working in
an extension project should always defer to that project's own CLAUDE.md and
instructions over anything stated here.

## Git Commit Guidelines

**IMPORTANT**: When creating commit messages, do not attribute commits to yourself (Claude). Commit messages should reflect the work being done without AI attribution in the message body. The standard Co-Authored-By trailer is acceptable.

## Critical: What This Repo Actually Is

**pgxntool is NOT a standalone project.** It is a meta-framework that exists ONLY to be embedded into PostgreSQL extension projects via `git subtree`. This repo cannot be built, tested, or run directly.

**Think of it like this**: pgxntool is to PostgreSQL extensions what a Makefile template library is to C projects - it's infrastructure code that gets copied into other projects, not a project itself.

## Critical: Directory Purity - NO Temporary Files

**This directory contains ONLY files that get embedded into extension projects.** When extension developers run `git subtree add`, they pull the entire pgxntool directory into their project.

**ABSOLUTE RULE**: NO temporary files, scratch work, or development tools may be added to this directory.

**Examples of what NEVER belongs here:**
- Temporary files (scratch notes, test output, debugging artifacts)
- Development scripts or tools (these go in pgxntool-test/)
- Planning documents (PLAN-*.md files go in pgxntool-test/)
- Any file you wouldn't want in every extension project that uses pgxntool

**CLAUDE.md exception**: CLAUDE.md exists here for AI assistant guidance, but is excluded from distributions via `.gitattributes export-ignore`. Same with `.claude/` directory.

**Why this matters**: Any file you add here will be pulled into hundreds of extension projects via git subtree. Keep this directory lean and clean.

## Development Workflow: Work from pgxntool-test

**CRITICAL**: All development work on pgxntool should be done from the pgxntool-test repository, NOT from this repository.

**For complete development workflow documentation, see:**
https://github.com/Postgres-Extensions/pgxntool-test

## Two-Repository Development Pattern

This codebase uses a two-repository pattern:

1. **pgxntool/** (this repo) - The framework code that gets embedded into extension projects
2. **pgxntool-test** - The test harness that validates pgxntool functionality

**For development and testing workflow, see:**
https://github.com/Postgres-Extensions/pgxntool-test

## How Extension Developers Use pgxntool

Extension projects include pgxntool via git subtree:

```bash
git subtree add -P pgxntool --squash git@github.com:decibel/pgxntool.git release
pgxntool/setup.sh
```

After setup, their Makefile typically contains just:
```makefile
include pgxntool/base.mk
```

## Architecture: Two-Phase Build System

### Phase 1: Meta Generation (`build_meta.sh`)
- Processes `META.in.json` (template with placeholders/empty values)
- Strips out X_comment fields and empty values
- Produces clean `META.json`

### Phase 2: Variable Extraction (`meta.mk.sh`)
- Parses `META.json` using `JSON.sh` (a bash-based JSON parser)
- Generates `meta.mk` with Make variables:
  - `PGXN` - distribution name
  - `PGXNVERSION` - version number
  - `EXTENSIONS` - list of extensions provided
  - `EXTENSION_*_VERSION` - per-extension versions
  - `EXTENSION_VERSION_FILES` - auto-generated versioned SQL files
- `base.mk` includes `meta.mk` via `-include`

### The Magic of base.mk

`base.mk` provides a complete PGXS-based build system:
- Auto-detects extension SQL files in `sql/`
- Auto-detects C modules in `src/*.c`
- Auto-detects tests in `test/sql/*.sql`
- Auto-generates versioned extension files (`extension--version.sql`)
- Handles Asciidoc → HTML conversion
- Integrates with PGXN distribution format
- Manages git tagging and release packaging

## File Structure for Consumer Projects

Projects using pgxntool follow this layout:
```
project/
├── Makefile                    # include pgxntool/base.mk
├── META.in.json               # Template metadata (customize for your extension)
├── META.json                  # Auto-generated from META.in.json
├── extension.control          # Standard PostgreSQL control file
├── pgxntool/                  # This repo, embedded via git subtree
├── sql/
│   └── extension.sql          # Base extension SQL
├── src/                       # Optional C code (*.c files)
├── test/
│   ├── deps.sql              # Load extension and test dependencies
│   ├── sql/*.sql             # Test SQL files
│   └── expected/*.out        # Expected test outputs
└── doc/                       # Optional docs (*.adoc, *.asciidoc)
```

## Commands for Extension Developers (End Users)

These are the commands extension developers use (documented for context):

```bash
make                    # Build extension (generates versioned SQL, docs)
make test              # Full test: testdeps → install → installcheck → show diffs
make results           # Run tests and update expected output files
make html              # Generate HTML from Asciidoc sources
make tag               # Create git branch for current META.json version
make dist              # Create PGXN .zip (auto-tags, places in ../)
make pgtle             # Generate pg_tle registration SQL (see pg_tle Support below)
make check-pgtle       # Check pg_tle installation and report version
make install-pgtle    # Install pg_tle registration SQL files into database
make pgxntool-sync     # Update to latest pgxntool via git subtree pull
```

## Testing with pgxntool

### Critical Testing Rules

**NEVER use `make installcheck` directly**. Always use `make test` instead. The `make test` target ensures:
- Clean builds before testing
- Proper test isolation
- Correct test dependency installation
- Proper cleanup and result comparison

**Database Connection Requirement**: PostgreSQL must be running before executing `make test`. If you get connection errors (e.g., "could not connect to server"), stop and ask the user to start PostgreSQL.

**Claude Code MUST NEVER run `make results`**. This target updates test expected output files and requires manual human verification of test changes before execution.

**Claude Code MUST NEVER modify files in `test/expected/`**. These are expected test outputs that define correct behavior and must only be updated through the `make results` workflow.

The workflow is:
1. Human runs `make test` and examines diffs
2. Human manually verifies changes are correct
3. Human manually runs `make results` to update expected files

### Test Output Mechanics

pgxntool uses PostgreSQL's pg_regress test framework:
- **Actual test output**: Written to `test/results/` directory
- **Expected output**: Stored in `test/expected/` directory
- **Test comparison**: pg_regress compares actual vs expected and generates diffs; `make test` displays them
- **Updating expectations**: `make results` copies `test/results/` → `test/expected/`

When tests fail, examine the diff output carefully. The actual test output in `test/results/` shows what your code produced, while `test/expected/` shows what was expected.

## Key Implementation Details

### PostgreSQL Version Handling
- `MAJORVER` = version × 10 (e.g., 9.6 → 96, 13 → 130)
- Tests use `--load-language=plpgsql` for versions < 13
- Version detection via `pg_config --version`

### Test System (pg_regress based)
- Tests in `test/sql/*.sql`, outputs compared to `test/expected/*.out`
- Setup via `test/pgxntool/setup.sql` (loads pgTap and deps.sql)
- `.IGNORE: installcheck` allows `make test` to handle errors (show diffs, then exit with error status)
- `make results` updates expected outputs after test runs

### Document Generation
- Auto-detects `asciidoctor` or `asciidoc`
- Generates HTML from `*.adoc` and `*.asciidoc` in `$(DOC_DIRS)`
- HTML required for `make dist`, optional for `make install`
- Template-based rules via `ASCIIDOC_template`

### Distribution Packaging
- `make dist` creates `../PGXN-VERSION.zip`
- Always creates git branch tag matching version
- Uses `git archive` to package
- Validates repo is clean before tagging

### Subtree Sync Support
- `make pgxntool-sync` pulls latest release
- Multiple sync targets: release, stable, local variants
- Uses `git subtree pull --squash`
- Requires clean repo (no uncommitted changes)

### pg_tle Support

pgxntool can generate pg_tle (Trusted Language Extensions) registration SQL for deploying extensions in AWS RDS/Aurora without filesystem access.

**Usage:** `make pgtle` or `make pgtle PGTLE_VERSION=1.5.0+`

**Output:** `pg_tle/{version_range}/{extension}.sql`

**For version range details and API compatibility boundaries, see:** `pgtle_versions.md`

**Installation targets:**

- `make check-pgtle` - Checks if pg_tle is installed and reports the version. Reports version from `pg_extension` if extension has been created, or newest available version from `pg_available_extension_versions` if available but not created. Errors if pg_tle not available in cluster. Assumes `PG*` environment variables are configured.

- `make install-pgtle` - Auto-detects pg_tle version and installs appropriate registration SQL files. Updates or creates pg_tle extension as needed. Determines which version range files to install based on detected version. Runs all generated SQL files via `psql` to register extensions with pg_tle. Assumes `PG*` environment variables are configured.

**Version notation:**
- `X.Y.Z+` means >= X.Y.Z
- `X.Y.Z-A.B.C` means >= X.Y.Z and < A.B.C (note boundary)

**Key implementation details:**
- Script: `pgxntool/pgtle-wrap.sh` (bash)
- Parses `.control` files for metadata (NOT META.json)
- Fixed delimiter: `$_pgtle_wrap_delimiter_$` (validated not in source)
- Each output file contains ALL versions and ALL upgrade paths
- Multi-extension support (multiple .control files)
- Output directory `pg_tle/` excluded from git
- Depends on `make all` to ensure versioned SQL files exist first
- Only processes versioned files (`sql/{ext}--{version}.sql`), not base files

**SQL file handling:**
- **Version files** (`sql/{ext}--{version}.sql`): Generated automatically by `make all` from base `sql/{ext}.sql` file
- **Upgrade scripts** (`sql/{ext}--{v1}--{v2}.sql`): Created manually by users when adding new extension versions
- The script ensures the default_version file exists if the base file exists (creates it from base file if missing)
- All version files and upgrade scripts are discovered and included in the generated pg_tle registration SQL

**Dependencies:**
Generated files depend on:
- Control file (metadata source)
- All SQL files (sql/{ext}--*.sql) - must run `make all` first
- Generator script itself

**Limitations:**
- No C code support (pg_tle requires trusted languages only)
- PostgreSQL 14.5+ required (pg_tle not available on earlier versions)

## Critical Gotchas

1. **Empty Variables**: If `DOCS` or `MODULES` is empty, base.mk sets to empty to prevent PGXS errors
2. **testdeps Pattern**: Never add recipes to `testdeps` - create separate target and make it a prerequisite
3. **META.json is Generated**: Always edit `META.in.json`, never `META.json` directly
4. **Control File Versions**: No automatic validation that `.control` matches `META.json` version
5. **PGXNTOOL_NO_PGXS_INCLUDE**: Setting this skips PGXS inclusion (for special scenarios)
6. **Distribution Placement**: `.zip` files go in parent directory (`../`) to avoid repo clutter

## Scripts

- **setup.sh** - Initializes pgxntool in a new extension project (copies templates, creates directories)
- **build_meta.sh** - Strips empty fields from META.in.json to create META.json
- **meta.mk.sh** - Parses META.json via JSON.sh and generates meta.mk with Make variables
- **JSON.sh** - Third-party bash JSON parser (MIT licensed)
- **safesed** - Utility for safe sed operations

## Related Repositories

- **pgxntool-test** - Test harness for validating pgxntool functionality: https://github.com/Postgres-Extensions/pgxntool-test
- Never produce any kind of metrics or estimates unless you have data to back them up. If you do have data you MUST reference it.