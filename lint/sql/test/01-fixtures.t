#!/usr/bin/env perl
#
# Data-driven fixture tests for sql-lint.
#
# Good fixtures (*.good.sql): must produce zero findings.
# Bad fixtures (*.bad.sql): must have a "-- expect-findings: N" header
#   and produce exactly N findings.
#
# Adding a new fixture requires NO changes to this file.

use strict;
use warnings;
use Test::More;
use File::Basename;
use File::Spec;

my $test_dir = dirname(__FILE__);
my $lint     = File::Spec->catfile($test_dir, '..', 'bin', 'sql-lint');

# -- Good fixtures: zero findings each ----------------------------------------

my @good = sort glob("$test_dir/fixtures/*.good.sql");
ok(@good > 0, 'found good fixtures') or BAIL_OUT('no good fixtures');

subtest 'good fixtures produce zero findings' => sub {
    plan tests => scalar @good;
    for my $file (@good) {
        my $name   = basename($file);
        my $output = `$lint -q "$file" 2>&1`;
        my $rc     = $? >> 8;
        is($rc, 0, "$name: clean") or diag($output);
    }
};

# -- Bad fixtures: expected finding counts from header -------------------------

my @bad = sort glob("$test_dir/fixtures/*.bad.sql");
ok(@bad > 0, 'found bad fixtures') or BAIL_OUT('no bad fixtures');

subtest 'bad fixtures produce expected findings' => sub {
    plan tests => scalar @bad * 2;
    for my $file (@bad) {
        my $name     = basename($file);
        my $expected = parse_expect($file);

        if (!defined $expected) {
            fail("$name: missing '-- expect-findings: N' header");
            fail("$name: (skipped count check)");
            next;
        }

        my $output = `$lint -q "$file" 2>&1`;
        my $rc     = $? >> 8;
        isnt($rc, 0, "$name: non-zero exit");

        my @lines = grep { /\S/ } split /\n/, $output;
        is(scalar @lines, $expected, "$name: $expected finding(s)")
            or diag($output);
    }
};

done_testing();

sub parse_expect {
    my ($file) = @_;
    open my $fh, '<', $file or return undef;
    while (<$fh>) {
        return $1 if /^--\s*expect-findings:\s*(\d+)/;
        last unless /^--/;
    }
    return undef;
}
