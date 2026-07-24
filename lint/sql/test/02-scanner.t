#!/usr/bin/env perl
#
# Scanner behavior and regression tests for sql-lint.
#
# Use this file for:
#   - Scanner-specific edge cases (state transitions, nesting)
#   - Regression tests for specific bugs (1-5 line SQL snippets)
#   - Behavior assertions on finding content (not just count)
#
# Use fixtures (01-fixtures.t) for whole-file patterns instead.

use strict;
use warnings;
use Test::More;
use File::Basename;
use File::Spec;
use File::Temp qw(tempfile tempdir);

my $test_dir = dirname(__FILE__);
my $lint     = File::Spec->catfile($test_dir, '..', 'bin', 'sql-lint');

# -- Helpers -------------------------------------------------------------------

sub lint_string {
    my ($sql) = @_;
    my ($fh, $tmp) = tempfile(SUFFIX => '.sql', UNLINK => 1);
    print $fh $sql;
    close $fh;
    my $output = `$lint -q "$tmp" 2>&1`;
    my $rc     = $? >> 8;
    return ($rc, $output);
}

# Write $sql to $filename inside a fresh temp directory, then lint the
# directory itself (not the file directly) — for asserting which extensions
# the directory walk picks up.
sub lint_dir_with_file {
    my ($filename, $sql) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, $filename);
    open my $fh, '>', $path or die "cannot write $path: $!";
    print $fh $sql;
    close $fh;
    my $output = `$lint -q "$dir" 2>&1`;
    my $rc     = $? >> 8;
    return ($rc, $output);
}

sub scan_string {
    my ($sql) = @_;
    my ($fh, $tmp) = tempfile(SUFFIX => '.sql', UNLINK => 1);
    print $fh $sql;
    close $fh;
    return `$lint --scan "$tmp" 2>&1`;
}

# -- Scanner tests -------------------------------------------------------------

subtest 'scanner: CODE lines outside comments' => sub {
    my $out = scan_string("SELECT 1;\n");
    like($out, qr/^1\|CODE\|\.\|SELECT 1;$/, 'basic CODE line');
};

subtest 'scanner: block comment labeled COMMENT' => sub {
    my $out = scan_string("/*\n * comment\n */\nSELECT 1;\n");
    my @lines = split /\n/, $out;
    like($lines[0], qr/\|CODE\|.\|/,    'opening /* is CODE');
    like($lines[1], qr/\|COMMENT\|.\|/, 'body is COMMENT');
    like($lines[2], qr/\|COMMENT\|.\|/, 'closing */ is COMMENT');
    like($lines[3], qr/\|CODE\|.\|/,    'after close is CODE');
};

subtest 'scanner: nested block comments' => sub {
    my $out = scan_string("/* outer\n  /* inner */\nstill outer\n*/\nSELECT 1;\n");
    my @lines = split /\n/, $out;
    like($lines[2], qr/\|COMMENT\|.\|/, 'inner */ only closes inner — still in outer');
    like($lines[3], qr/\|COMMENT\|.\|/, 'outer closing */ is COMMENT');
    like($lines[4], qr/\|CODE\|.\|/,    'after outer close is CODE');
};

subtest 'scanner: /* inside string is not a comment' => sub {
    my $out = scan_string("SELECT '/* not a comment */';\nSELECT 2;\n");
    my @lines = split /\n/, $out;
    like($lines[0], qr/\|CODE\|.\|/, 'line with /* in string is CODE');
    like($lines[1], qr/\|CODE\|.\|/, 'next line is still CODE');
};

subtest 'scanner: -- prevents /* from opening block' => sub {
    my $out = scan_string("SELECT 1; -- /* not a block comment\nSELECT 2;\n");
    my @lines = split /\n/, $out;
    like($lines[1], qr/\|CODE\|.\|/, 'next line is CODE (/* was in line comment)');
};

subtest 'scanner: /* in comment body increments depth' => sub {
    # This is PostgreSQL-correct: /* inside /* */ is nested.
    # The single */ only closes the inner one.
    my $out = scan_string("/*\n * mentions /* in prose\n */\nSELECT 1;\n");
    my @lines = split /\n/, $out;
    like($lines[3], qr/\|COMMENT\|.\|/,
        'SELECT after */ is still COMMENT — nested /* needs its own */');
};

# -- Regression tests ----------------------------------------------------------

subtest 'comma inside single-quoted string is not flagged' => sub {
    my ($rc, $out) = lint_string("SELECT 'hello,';\n");
    is($rc, 0, 'exit 0');
};

subtest 'pure -- comment line with comma not flagged as trailing-comma' => sub {
    my ($rc, $out) = lint_string("-- SELECT a,\n-- SELECT b,\nSELECT 1;\n");
    unlike($out, qr/trailing-comma/, 'no trailing-comma finding');
};

subtest '/* inside single-quoted string not flagged as comment-opening' => sub {
    my ($rc, $out) = lint_string("SELECT '/* not a comment';\n");
    is($rc, 0, 'exit 0');
};

subtest 'comma after /* on same line not flagged as trailing-comma' => sub {
    my ($rc, $out) = lint_string("/* text,\n */\nSELECT 1;\n");
    unlike($out, qr/trailing-comma/, 'no trailing-comma finding');
};

subtest '/* */ inside -- comment not flagged as comment-single-line' => sub {
    my ($rc, $out) = lint_string("-- Use /* */ for multi-line comments.\nSELECT 1;\n");
    unlike($out, qr/comment-single-line/, 'no comment-single-line finding');
};

subtest '/* */ inside string not flagged as comment-single-line' => sub {
    my ($rc, $out) = lint_string("SELECT '/* not a comment */';\n");
    unlike($out, qr/comment-single-line/, 'no comment-single-line finding');
};

subtest 'properly formatted block comment is clean' => sub {
    my ($rc, $out) = lint_string("/*\n * First line.\n *\n * Third line.\n */\nSELECT 1;\n");
    unlike($out, qr/comment-line-prefix/, 'no comment-line-prefix finding');
};

subtest 'indented block comment is clean' => sub {
    my $sql = <<'SQL';
CREATE FUNCTION f() RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
	/*
	 * Indented block comment.
	 */
	RAISE NOTICE 'hi';
END;
$body$;
SQL
    my ($rc, $out) = lint_string($sql);
    unlike($out, qr/comment-line-prefix/, 'no comment-line-prefix finding');
    unlike($out, qr/comment-closing/,     'no comment-closing finding');
};

subtest 'closing */ alone on its line is clean' => sub {
    my ($rc, $out) = lint_string("/*\n * Comment.\n */\nSELECT 1;\n");
    unlike($out, qr/comment-closing/, 'no comment-closing finding');
};

subtest 'findings are sorted by line number' => sub {
    my ($rc, $out) = lint_string("-- line one\n-- line two\n\n/* bad opening text\n */\n\nSELECT a,\n");
    my @nums = $out =~ /:(\d+):/g;
    my @sorted = sort { $a <=> $b } @nums;
    is_deeply(\@nums, \@sorted, 'findings in line order');
};

subtest 'empty file produces no findings' => sub {
    my ($rc, $out) = lint_string('');
    is($rc, 0, 'exit 0');
};

subtest 'exit code encodes finding count' => sub {
    my ($rc, $out) = lint_string("SELECT a,\n");
    is($rc, 11, 'exit 11 = 1 finding + 10');
};

subtest '-- /* line not flagged as comment-opening' => sub {
    my ($rc, $out) = lint_string("-- /* this is a line comment\nSELECT 1;\n");
    unlike($out, qr/comment-opening/, 'no comment-opening finding');
};

subtest 'code after inline /* -- */ comment is not lost' => sub {
    my ($rc, $out) = lint_string("CREATE TABLE t(a /* flag -- TODO */ integer);\n");
    like($out, qr/prefer-short-type/, 'integer after inline comment is still linted');
};

subtest 'verbose type suggestions are correct' => sub {
    my ($rc, $out) = lint_string("CREATE TABLE t(a integer, b bool, c int2);\n");
    like($out, qr/"int" instead of "integer"/, 'integer -> int');
    like($out, qr/"boolean" instead of "bool"/, 'bool -> boolean');
    like($out, qr/"smallint" instead of "int2"/, 'int2 -> smallint');
};

subtest 'inline suppression prevents finding' => sub {
    my ($rc, $out) = lint_string(
        "SELECT a, -- sql-lint:disable trailing-comma\n");
    is($rc, 0, 'suppressed finding exits 0');
};

subtest 'block suppression: disable-block and EXCLUDED CODE alias' => sub {
    # Unprefixed code lines inside a /* */ block trip comment-line-prefix.
    my $body = "raw line, not prefixed\nSELECT not_ready(\n  foo\n  , bar\n);\n";

    my ($rc_bare) = lint_string("/*\n$body*/\nSELECT 1;\n");
    isnt($rc_bare, 0, 'plain /* */ block flags the unprefixed lines');

    my ($rc_db) = lint_string("/* sql-lint:disable-block all\n$body*/\nSELECT 1;\n");
    is($rc_db, 0, 'sql-lint:disable-block all suppresses the whole block');

    my ($rc_ex) = lint_string("/* EXCLUDED CODE\n$body*/\nSELECT 1;\n");
    is($rc_ex, 0, 'EXCLUDED CODE alias suppresses the whole block');

    my ($rc_ex2) = lint_string("/* EXCLUDED CODE: disabled until #123\n$body*/\nSELECT 1;\n");
    is($rc_ex2, 0, 'EXCLUDED CODE with a trailing description still suppresses');
};

subtest 'region suppression: disable-block/enable-block around real code' => sub {
    # Unlike the /* */-anchored disable-block above, this pair works on real
    # (uncommented) code and is closed explicitly rather than by a comment's
    # own */ -- e.g. for a chunk of borrowed code left deliberately
    # unreformatted.
    my ($rc_all, $out_all) = lint_string(
        "-- sql-lint:disable-block all\nSELECT a,\nSELECT b integer,\n-- sql-lint:enable-block\nSELECT c,\n");
    isnt($rc_all, 0, 'finding after enable-block still flagged');
    unlike($out_all, qr/:2:|:3:/, 'no findings inside the disable-block/enable-block region');
    like($out_all, qr/:5:/, 'finding on line 5 (after enable-block) still reported');

    my (undef, $out_rule) = lint_string(
        "-- sql-lint:disable-block trailing-comma\nSELECT a integer,\n-- sql-lint:enable-block\n");
    like($out_rule, qr/prefer-short-type/, 'disabling one rule does not suppress other rules in the region');
    unlike($out_rule, qr/trailing-comma/, 'disabling one rule does suppress that rule in the region');

    my ($rc_unclosed) = lint_string("-- sql-lint:disable-block all\nSELECT a,\nSELECT b,\n");
    is($rc_unclosed, 0, 'unclosed disable-block suppresses through EOF');
};

subtest 'multi-line single-quoted string keeps state across lines' => sub {
    my $out = scan_string("SELECT 'start\n/* inside the string\nend';\nSELECT 2;\n");
    my @lines = split /\n/, $out;
    like($lines[1], qr/\|CODE\|S\|/, 'continuation line inside string has in_string=S');
    like($lines[3], qr/\|CODE\|\.\|/, 'code after string close is CODE with no in_string');
};

subtest 'multi-line string does not cause trailing-comma false positive' => sub {
    my ($rc, $out) = lint_string("SELECT 'hello,\nworld';\n");
    unlike($out, qr/trailing-comma/, 'comma inside multi-line string not flagged');
};

subtest 'multi-line string continuation line not checked for types' => sub {
    my ($rc, $out) = lint_string("SELECT 'integer\nbool';\n");
    unlike($out, qr/prefer-short-type/, 'type name inside multi-line string not flagged');
};

subtest 'trailing comma before -- with no leading space is flagged' => sub {
    # code_content must strip the line comment even without whitespace before --,
    # matching the scanner which treats -- as a comment start unconditionally.
    my ($rc, $out) = lint_string("SELECT a,--comment\nSELECT 1;\n");
    like($out, qr/trailing-comma/, 'trailing comma detected when -- has no leading space');
};

subtest '-- with no leading space hides a following /* (no false comment-opening)' => sub {
    # `1--x /* y`: -- starts a line comment, so the /* is inside it and must not
    # be treated as a block-comment opener. The per-rule -- stripping must match
    # the scanner (no leading-whitespace requirement).
    my ($rc, $out) = lint_string("SELECT 1--x /* y\nSELECT 2;\n");
    unlike($out, qr/comment-opening/, 'no false comment-opening when -- has no leading space');
};

subtest '-- with no leading space hides a following /* */ (no false comment-single-line)' => sub {
    my ($rc, $out) = lint_string("SELECT 1--x /* c */\nSELECT 2;\n");
    unlike($out, qr/comment-single-line/, 'no false comment-single-line when -- has no leading space');
};

# -- Edge cases ----------------------------------------------------------------

subtest 'no arguments prints usage and exits 2' => sub {
    my $out = `$lint 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 2, 'exit 2 for no args');
};

subtest 'nonexistent file exits 2' => sub {
    my $out = `$lint -q /nonexistent/file.sql 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 2, 'exit 2 for missing file');
};

subtest 'directory scanning finds files' => sub {
    my ($rc, $out) = lint_string("SELECT 1;\n");
    is($rc, 0, 'clean file via directory');
};

subtest 'directory scanning finds .sql.in files' => sub {
    # cat_tools authors the hand-maintained SQL source as a .sql.in template
    # expanded at build time; the directory walk must not skip it.
    my ($rc, $out) = lint_dir_with_file('example.sql.in', "SELECT a,\n");
    like($out, qr/trailing-comma/, '.sql.in file was scanned and linted');
};

subtest '.sql.in generated-file marker still skips the file' => sub {
    my ($rc, $out) = lint_dir_with_file('example.sql.in',
        "-- GENERATED FILE! DO NOT EDIT! See source.sql.in\nSELECT a,\n");
    is($rc, 0, 'marker (GENERATED ... DO NOT EDIT, either order) skips the file');
};

done_testing();
