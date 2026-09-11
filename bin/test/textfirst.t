#!/usr/bin/env perl
#
# One case per rule bin/update_lint_textfirst implements, plus the two things
# only the real tree can prove: that the current development pair is clean, and
# that the ALTER DEFAULT PRIVILEGES rule reproduces the historical bug it was
# written for. Kept deliberately small -- a checker whose test suite dwarfs it
# has stopped being the cheap option. Run from the repo root:
#
#     prove bin/test/textfirst.t

use strict;
use warnings;
use Test::More tests => 31;
use File::Temp qw(tempdir);

my $PROG = 'bin/update_lint_textfirst';
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
    my $out = qx{$^X $PROG @p 2>&1};
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

# --- enum labels ------------------------------------------------------------

{
    my ($rc, $out) = run_trio(
        old    => "CREATE TYPE e AS ENUM ('a', 'b');\n",
        new    => "CREATE TYPE e AS ENUM ('a', 'b', 'c');\n",
        update => "ALTER TYPE e ADD VALUE 'c';\n",
    );
    is $rc, 0, 'an added enum label covered by ALTER TYPE ... ADD VALUE is clean';
    like $out, qr/enum 1,/, '... and is counted as an enum pairing, not a copy';
}

{
    # BEFORE/AFTER is how a label lands anywhere but the end, and says nothing
    # about whether the label is present.
    my ($rc) = run_trio(
        old    => "CREATE TYPE e AS ENUM ('a', 'c');\n",
        new    => "CREATE TYPE e AS ENUM ('a', 'b', 'c');\n",
        update => "ALTER TYPE e ADD VALUE 'b' BEFORE 'c';\n",
    );
    is $rc, 0, 'an ADD VALUE with a BEFORE clause still counts';
}

{
    my ($rc, $out) = run_trio(
        old    => "CREATE TYPE e AS ENUM ('a', 'b');\n",
        new    => "CREATE TYPE e AS ENUM ('a', 'b', 'c');\n",
        update => "ALTER TYPE e ADD VALUE 'b';\n",
    );
    is $rc, 1, 'an added enum label with no ALTER TYPE fails';
    like $out, qr/enum e gained label 'c'/, '... naming the label, not the whole type';
}

{
    my ($rc, $out) = run_trio(
        old    => "CREATE TYPE e AS ENUM ('a', 'b');\n",
        new    => "CREATE TYPE e AS ENUM ('a');\n",
        update => "SELECT 1;\n",
    );
    is $rc, 1, 'a removed enum label fails';
    like $out, qr/cannot be removed by an update script/, '... saying no update can do it';
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

# --- against the real tree --------------------------------------------------

SKIP: {
    skip 'run from the repo root', 6 unless -e 'sql/cat_tools--0.2.1.sql.in';

    # No arguments at all: the pair every SQL-touching PR is judged on. It has
    # to be clean, or the CI step this drives is useless from the day it lands.
    my $out = qx{$^X $PROG 2>&1};
    is $? >> 8, 0, 'the current development pair is clean';
    like $out, qr{new sql/cat_tools\.sql\.in\b}, '... comparing against the base install script';
    like $out, qr{update sql/cat_tools--\S+--stable\.sql\.in}, '... via the accumulator update script';

    # A released install script is a copy of the base file with sql.mk's
    # " VERSIONED FILE!" tag added to every @generated@ marker. One of those
    # markers sits inside a dollar-quoted function body where no comment strip
    # can reach it, so the pair above is only clean if preprocessing erases the
    # difference.
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
