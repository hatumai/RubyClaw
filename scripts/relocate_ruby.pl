#!/usr/bin/env perl
# Perl fallback for scripts/relocate_ruby.py — for boxes with no python3 but with
# perl (which Debian/Ubuntu treat as part of the base system). Same algorithm, same
# two traps; see the Python file for the full explanation.
#
#   relocate_ruby.pl <new-prefix> [tree-dir]
use strict;
use warnings;
use File::Find;
use File::Spec;

my $new = shift or die "usage: relocate_ruby.pl <new-prefix> [tree-dir]\n";
$new =~ s{/$}{};
my $tree = shift // $new;
my $root = File::Spec->rel2abs($tree);
$root =~ s{/$}{};
my $old = "";

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $b = <$fh>;
    close $fh;
    return $b;
}

sub spew {
    my ($p, $b) = @_;
    open my $fh, '>:raw', $p or die "cannot write $p: $!\n";
    print {$fh} $b;
    close $fh;
}

# Find the baked-in toolcache prefix by reading it out of bin/ruby.
unless (length $old) {
    my $b = slurp("$root/bin/ruby");
    die "! $root/bin/ruby not found — is that a ruby-builder tarball?\n" unless defined $b;
    if ($b =~ m{(/opt/hostedtoolcache/Ruby/[^/\x00]+/[^/\x00]+)}) { $old = $1 }
    else { print "= $root: no toolcache prefix baked in, nothing to relocate\n"; exit 0 }
}

die "! install prefix must be <= " . length($old) . " bytes, got " . length($new) . ": $new\n"
    if length($new) > length($old);
print "= relocating $old -> $new\n";

my $pad = length($old) - length($new);

# Repack NUL-separated runs of paths tightly, padding only after the run's own
# terminator, so the list parser never sees an empty entry ahead of the real end.
sub repack_lists {
    my ($b) = @_;
    my $count = 0;
    my $pos = 0;
    while ((my $at = index($b, "\0" . $old, $pos)) >= 0) {
        my $start = $at + 1;
        my $p = $start;
        my @entries;
        while (substr($b, $p, length($old)) eq $old) {
            my $q = index($b, "\0", $p);
            last if $q < 0;
            my $e = substr($b, $p, $q - $p);
            $e =~ s/\Q$old\E/$new/g;
            push @entries, $e;
            $p = $q + 1;
        }
        my $region = $p - $start;
        my $block = join("\0", @entries) . "\0";
        die "! new prefix is not shorter than the old one\n" if length($block) > $region;
        substr($b, $start, $region) = $block . ("\0" x ($region - length($block)));
        $count++;
        $pos = $start + $region;
    }
    return ($b, $count);
}

sub fix_elf {
    my ($b) = @_;
    my ($n, $lists) = repack_lists($b);
    # remaining occurrences are offset-addressed: replace and pad at the end
    my $out = '';
    my $pos = 0;
    while ((my $i = index($n, $old, $pos)) >= 0) {
        my $q = index($n, "\0", $i);
        $q = length($n) if $q < 0;
        $out .= substr($n, $pos, $i - $pos) . $new . substr($n, $i + length($old), $q - $i - length($old));
        $out .= "\0" x $pad;
        $pos = $q;
    }
    $out .= substr($n, $pos);
    return ($out, $lists);
}

my ($elf, $txt, $lists) = (0, 0, 0);
find(
    sub {
        return unless -f $_ && !-l $_;
        my $b = slurp($_) or return;
        return if index($b, $old) < 0;
        if (substr($b, 0, 4) eq "\x7fELF") {
            my ($nb, $n) = fix_elf($b);
            spew($_, $nb);
            $lists += $n;
            $elf++;
        } else {
            $b =~ s/\Q$old\E/$new/g;
            spew($_, $b);
            $txt++;
        }
    },
    $root
);
print "= patched $elf binaries, $txt text files, $lists NUL-separated arrays\n";
