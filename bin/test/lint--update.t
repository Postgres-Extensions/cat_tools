#!/usr/bin/env perl
#
# Self-test for bin/lint--update: feeds it synthetic OLD/NEW/UPDATE scripts and
# asserts its exit code and output. It does not test the SQL itself.
# Run it from the repo root with `make test-bin`, or alone with
# `prove bin/test/lint--update.t`. CI's `lint` job runs `make test-bin` before
# `make lint--update`, so a checker bug is not reported as a finding against
# the SQL.
#
# One case per rule bin/lint--update implements, plus the three things only the
# real tree can prove: that the current development pair is clean, that the
# ALTER DEFAULT PRIVILEGES rule reproduces the historical bug it was written
# for, and that the @generated@ marker inside a function body causes no false
# positive.
#
# Kept deliberately small: a checker whose test suite dwarfs it has stopped
# being the cheap option.

use strict;
use warnings;
use Test::More tests => 52;
use File::Temp qw(tempdir);

my $PROG = 'bin/lint--update';
my $DIR  = tempdir(CLEANUP => 1);

# Write an OLD/NEW/UPDATE trio and run the linter over it.
sub run_trio {
    my (%f) = @_;
    my @p;
    for my $k (qw(old new update)) {
        my $p = "$DIR/$k.sql";
        open my $fh, '>', $p or die $!;
        print $fh $f{$k} // '';
        close $fh;
        push @p, $p;
    }
    my $out = qx{$^X $PROG @{$f{flags} // []} @p 2>&1};
    return ($? >> 8, $out);
}

# --- the splitter -----------------------------------------------------------

{
    # A `;` inside a string, a quoted identifier, a comment and a dollar-quoted
    # body must not end a statement. If any did, NEW would hold extra
    # statements OLD lacks and they would be reported as added.
    my $sql = <<'SQL';
SELECT 'a;b';
SELECT "we;ird";
SELECT 1; -- trailing ; comment
CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $body$
BEGIN
  /* nested /* block ; comment */ still in here ; */
  RETURN 1;
END
$body$;
SQL
    my ($rc, $out) = run_trio(old => $sql, new => $sql, update => '');
    is $rc, 0, 'identical files are clean';
    like $out, qr/old \S+ \(4 statements\)/, 'four top-level statements found';
}

# --- comments: kept inside a statement, dropped between statements ----------

{
    my ($rc) = run_trio(
        old    => "SELECT 1;\n-- old note\nSELECT 2;\n",
        new    => "SELECT 1;\n-- new note, reworded\nSELECT 2;\n",
        update => '',
    );
    is $rc, 0, 'a comment between statements that changed in NEW only is ignored';
}

{
    my ($rc, $out) = run_trio(
        old    => "SELECT 1, -- old note\n  2;\n",
        new    => "SELECT 1, -- new note\n  2;\n",
        update => "SELECT 2;\n",
    );
    is $rc, 1, 'a comment inside a statement that changed in NEW only is a finding';
    like $out, qr/-- new note/, '... and the kept comment is part of the reported text';
}

{
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\n-- about t\nCREATE TABLE t (a int);\n",
        update => "CREATE TABLE t (a int);\n",
    );
    is $rc, 0, 'a new statement copied without the comment before it is matched';
}

{
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nSELECT a, -- SED: REQUIRES 9.3!\n  b;\n",
        update => "SELECT a,\n  b;\n",
    );
    is $rc, 1, 'a statement whose trailing SED comment is missing from the copy is a finding';
    like $out, qr/SED: REQUIRES 9\.3!/, '... and the finding shows the dropped comment';
}

{
    # The newline ending a kept `--` comment must stay visible, or code moving
    # across it compares equal.
    my ($rc) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nSELECT 1, -- note 2\n;\n",
        update => "SELECT 1, -- note\n 2;\n",
    );
    is $rc, 1, 'code moving onto a kept -- comment line is a finding';
}

# --- the @generated@ marker -------------------------------------------------

{
    my ($rc, $out) = run_trio(
        old    => "/* see \@generated\@ */\nSELECT 1;\n",
        new    => "/* see \@generated\@ */\nSELECT 1;\nCREATE TABLE t(a int);\n",
        update => '',
    );
    is $rc, 2, 'text after @generated@ other than the VERSIONED tag is an error, not a silent OK';
    like $out, qr/:1: text after \@generated\@/, '... naming the line';
}

{
    my $body = "CREATE FUNCTION f() RETURNS int LANGUAGE sql AS \$b\$\n  SELECT 1; -- \@generated\@%s\n\$b\$;\n";
    my ($rc) = run_trio(
        old    => sprintf($body, ' VERSIONED FILE!'),
        new    => sprintf($body, ''),
        update => '',
    );
    is $rc, 0, '@generated@ and @generated@ VERSIONED FILE! inside a dollar-quoted body compare equal';
}

# --- rule 4: substring against the whole update file ------------------------

{
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nCREATE TABLE t (a int);\n",
        # Wrapped in a DO block, so it is not a top-level statement over here.
        update => "DO \$\$ BEGIN EXECUTE 'CREATE TABLE t (a int)'; END \$\$;\n",
    );
    is $rc, 0, 'a copy buried in a DO block satisfies the added statement';
    like $out, qr/added 1 \(matched 1,/, '... and is counted as matched';
}

{
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nCREATE TABLE t (a int);\n",
        update => "SELECT 2;\n",
    );
    is $rc, 1, 'an added statement with no copy fails';
    like $out, qr/CREATE TABLE t \(a int\)/, '... and is named in the finding';
}

# --- enum labels, which are out of scope ------------------------------------

{
    # The pgTAP suite asserts enum contents against the catalog across fresh,
    # updated and pg_upgraded databases, so this does not second-guess it.
    my ($rc, $out) = run_trio(
        old    => "CREATE TYPE e AS ENUM ('a', 'b');\n",
        new    => "CREATE TYPE e AS ENUM ('a', 'b', 'c');\n",
        update => "SELECT 1;\n",
    );
    is $rc, 0, 'a changed enum on a pre-existing type is exempt';
    like $out, qr/enum 1,/, '... and the exemption is reported, not silent';
}

{
    # Only CHANGED enums are exempt. A brand-new one copies into the update
    # script verbatim, so the ordinary rule has to keep applying to it.
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nCREATE TYPE e AS ENUM ('a');\n",
        update => "SELECT 2;\n",
    );
    is $rc, 1, 'a brand-new enum type is still checked for a copy';
    like $out, qr/CREATE TYPE e AS ENUM/, '... and is named in the finding';
}

# --- scaffolding ------------------------------------------------------------

{
    # __cat_tools is created and dropped inside the install script, so its
    # contents cannot differ between a fresh and an updated database.
    my ($rc, $out) = run_trio(
        old    => "CREATE FUNCTION __cat_tools.helper() RETURNS void LANGUAGE sql AS 'SELECT';\n",
        new    => "CREATE FUNCTION __cat_tools.helper(a int) RETURNS void LANGUAGE sql AS 'SELECT';\n",
        update => "SELECT 1;\n",
    );
    is $rc, 0, 'a changed scaffolding definition is exempt';
    like $out, qr/scaffolding 1,/, '... and the exemption is reported, not silent';
}

{
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nSELECT __cat_tools.create_function('cat_tools.f');\n",
        update => "SELECT 2;\n",
    );
    is $rc, 1, 'a CALL to scaffolding is still checked -- it creates a real object';
    like $out, qr/create_function\('cat_tools\.f'\)/, '... and is named in the finding';
}

# --- the escape hatch -------------------------------------------------------

{
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nCREATE TABLE t (a int);\n",
        update => "-- update-lint: ok /CREATE TABLE t/ hand-rewritten below\n"
                . "CREATE TABLE t (a int NOT NULL);\n",
    );
    is $rc, 0, 'a waiver suppresses the finding';
    like $out, qr/waived .*hand-rewritten below/, '... and prints its reason';
}

{
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\n",
        update => "-- update-lint: ok /nothing matches this/ stale\n",
    );
    is $rc, 1, 'a waiver that matches nothing fails';
    like $out, qr{stale waiver /nothing matches this/}, '... and says which one';
}

{
    # Whitespace closes the regex, not the first `/`. Closing at the first one
    # would waive /a/ here -- far wider than written, and silently.
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nSELECT a/b;\n",
        update => "-- update-lint: ok /a/b/ division is fine\n",
    );
    is $rc, 0, 'a waiver regex may contain a slash';
    like $out, qr/waived .*division is fine/, '... and keeps the whole reason';
}

# A typo must not degrade into "no waiver at all". Both of these would otherwise
# leave the author staring at a finding they believe they already waived.
for my $bad (
    ['-- update-lint: ok /CREATE TABLE t/',             'a waiver with no reason'],
    ['-- update-lint: okay /CREATE TABLE t/ mistyped',  'a mistyped waiver keyword'],
) {
    my ($line, $desc) = @$bad;
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\nCREATE TABLE t (a int);\n",
        update => "$line\n",
    );
    is $rc, 2, "$desc is a usage error, not a silent no-op";
    like $out, qr/malformed waiver/, '... naming it as malformed';
}

# --- ALTER DEFAULT PRIVILEGES -----------------------------------------------

{
    # Only one ADP shape is understood. A different one must say so rather than
    # pass as "nothing to see" -- a copy in the update script is not enough,
    # since ADP does not reach objects that already exist.
    my $adp = 'ALTER DEFAULT PRIVILEGES FOR ROLE r IN SCHEMA s GRANT USAGE ON TYPES TO u;';
    my ($rc, $out) = run_trio(
        old    => "SELECT 1;\n",
        new    => "SELECT 1;\n$adp\n",
        update => "$adp\n",
    );
    is $rc, 1, 'an ALTER DEFAULT PRIVILEGES form the rule cannot read fails';
    like $out, qr/unrecognized ALTER DEFAULT PRIVILEGES form/, '... saying so, not skipping it';
}

# --- --processed: the GENERATED FILE marker --------------------------------

{
    my $body = "CREATE FUNCTION f() RETURNS int LANGUAGE sql AS \$b\$\n  SELECT 1; -- GENERATED FILE! DO NOT EDIT! See sql/%s.sql.in%s\n\$b\$;\n";
    my %t = (
        old    => sprintf($body, 'cat_tools--0.3.0', ' VERSIONED FILE!'),
        new    => sprintf($body, 'cat_tools', ''),
        update => '',
    );
    my ($rc) = run_trio(%t, flags => ['--processed']);
    is $rc, 0, '--processed: GENERATED FILE marker, with and without VERSIONED FILE!, differs by path yet compares equal (dollar-quoted)';

    ($rc) = run_trio(%t);
    is $rc, 1, 'default mode does not apply the GENERATED normalization';

    my $bad = "SELECT 1; -- GENERATED FILE! DO NOT EDIT! See sql/x.sql.in */ SELECT 2;\n";
    my $out;
    ($rc, $out) = run_trio(old => $bad, new => $bad, update => '', flags => ['--processed']);
    is $rc, 2, '--processed: text after the marker other than the tag is an error';
    like $out, qr/:1: text after the GENERATED FILE marker/, '... naming the line';

    ($rc) = run_trio(old => "SELECT 1; -- \@generated\@ junk\n", new => "SELECT 1;\n", update => '', flags => ['--processed']);
    is $rc, 0, '--processed does not treat @generated@ as a marker';
}

# --- --processed: missing generated files, and the mode hint ----------------

{
    my $sd  = tempdir(CLEANUP => 1);
    my $cmd = "$^X $PROG --processed --sql-dir $sd --versions 1.0 2.0 2>&1";
    my $out = qx{$cmd};
    is $? >> 8, 2, '--processed with a missing derived file is a usage error, not a pass on /dev/null';
    like $out, qr/make update-lint-processed/, '... telling the user how to generate it';

    for my $f ("cat_tools--1.0.sql", "cat_tools--2.0.sql", "cat_tools--1.0--2.0.sql") {
        open my $fh, '>', "$sd/$f" or die $!;
        close $fh;
    }
    $out = qx{$cmd};
    is $? >> 8, 0, '--processed over the three (empty) derived files runs';
    like $out, qr/^  processed mode: .*fix the \.sql\.in.*make update-lint-processed/m,
        '... and prints the processed-mode hint';

    $out = qx{$^X $PROG --sql-dir $sd --versions 1.0 2.0 2>&1};
    unlike $out, qr/processed mode/, 'raw mode prints no processed-mode hint';
}

# --- against the real tree --------------------------------------------------

SKIP: {
    skip 'run from the repo root', 6 unless -e 'sql/cat_tools--0.2.1.sql.in';

    # No arguments at all: the pair every SQL-touching PR is judged on. It has
    # to be clean, or the CI step this drives is useless from the day it lands.
    my $out = qx{$^X $PROG 2>&1};
    is $? >> 8, 0, 'the current development pair is clean';
    like $out, qr{new sql/cat_tools\.sql\.in\b}, '... comparing against the base install script';
    like $out, qr{update sql/cat_tools--\S+--stable\.sql\.in}, '... via this cycle\'s update script';

    # One @generated@ marker sits inside a dollar-quoted function body, and a
    # released copy carries extra text after it. The pair above is only clean
    # because preprocessing deletes the marker through end of line.
    unlike $out, qr/create_function/, '... with no @generated@ tag false positive';

    $out = qx{$^X $PROG --versions 0.2.1 0.2.2 2>&1};
    my @gaps = $out =~ /^\S+: TYPE (\S+) predates/mg;
    is_deeply [sort @gaps], [sort qw(
        cat_tools.constraint_type cat_tools.procedure_type cat_tools.relation_type
        cat_tools.relation_relkind cat_tools.object_type
    )], 'the five enum types that never got GRANT USAGE are flagged';

    # ADP was already in force across this pair, so nothing predates it.
    $out = qx{$^X $PROG --versions 0.2.2 0.2.3 2>&1};
    unlike $out, qr/predates/, 'an ADP present in both installs raises nothing';
}
