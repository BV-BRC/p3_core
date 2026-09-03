#!/usr/bin/env perl
#
# Benchmark the RQL terms() operator against in(), by value-list size.
#
# Not a .t -- this is a measurement tool, not a pass/fail test. The pass/fail
# probe is p3-rql-terms.t next door, which answers "is terms() correct here";
# this answers "is it faster here", which turned out to be a separate question
# with a surprising answer.
#
#   perl t/client-tests/p3-rql-terms-bench.pl [url]
#
# Default url is alpha. Read-only: it issues select() queries against public
# Campylobacter genomes and writes nothing.
#
# What it measures, and why it is built the way it is
# ---------------------------------------------------
#
# Two cores, because they do not behave alike:
#
#   genome_feature / feature_id   -- one query per trial, so n really is the
#                                    size of the value list in a single query.
#   feature_sequence / md5        -- driven through lookup_sequence_data, which
#                                    batches internally at 500. n is therefore
#                                    total volume across 500-value queries, NOT
#                                    the query size. The two columns are not
#                                    the same experiment; do not read the md5
#                                    column as "terms() scales with list size".
#
# Three defences against measuring the wrong thing:
#
#   1. Best-of-3, not mean. A single sample on a shared endpoint is mostly
#      noise from someone else's query.
#   2. Alternating operator order per rep. Running in() first every time hands
#      terms() a warm document cache, which would flatter it.
#   3. Row counts compared at every size. A performance number from a query
#      that returned the wrong rows is worse than no number -- and returning
#      too few rows under a 200 is exactly how this operator failed before
#      (alpha truncated genome_feature to a one-byte body at limit >= 10000,
#      fixed 2026-09-03).
#
# One thing it deliberately does NOT do: re-send the same value list to compare
# operators across trials. terms() lands in &fq=, which Solr filter-caches, so a
# repeated identical list measures the cache. Each size uses one fixed list and
# the reps are close together, which is the honest comparison for a client that
# sends each list once; if you extend this, keep that property.
#
# Results on alpha AFTER the 2026-09-03 API fix (ratio = terms/in, <1 = terms
# faster). Row counts identical at every size on both cores:
#
#         n   genome_feature/feature_id   feature_sequence/md5
#       100                       0.40x                  0.49x
#       500                       0.48x                  0.82x
#      1500                       0.39x                  0.75x
#      5000                       0.39x                  0.82x
#     15000                       0.90x                  0.85x
#
#     co-occurring clause, n = 6000 fixed:
#       id list alone                                    0.35x
#       id list + in(feature_type,(mat_peptide,CDS))     0.41x
#
# terms() is now faster at every size on both cores, and the co-occurring clause
# costs it almost nothing.
#
# What the earlier numbers showed, and why the third bench exists
# ---------------------------------------------------------------
#
# Before that fix the picture was the reverse, and the shape of the query
# mattered more than the size of the list. Same 6,053 patric_ids in both rows:
#
#     patric_id  alone                    in 2.38s / terms 2.05s   0.86x
#     patric_id  + in(feature_type,...)   in 2.24s / terms 3.70s   1.65x
#
# A second clause -- not the one under test -- flipped terms() from a small win
# to a large loss, because of where each operator lands. With both as in(),
# Solr gets one boolean query and can lead with the selective id clause:
#
#     q  = feature_type:(mat_peptide OR CDS) AND patric_id:(...6053 values...)
#
# With terms(), the id list moves to &fq= and what was left to *score* was:
#
#     q  = feature_type:(mat_peptide OR CDS)   <- ~the whole genome_feature core
#     fq = {!terms f=patric_id}...6053 values...
#
# The hash-set filter was cheap, but Solr then scored hundreds of millions of
# documents instead of 6,053 -- a cost terms() created by vacating the query.
# That hit two of the six gated call sites in P3DataAPI
# (retrieve_protein_feature_sequence and retrieve_nucleotide_feature_sequence
# both carry in(feature_type,...)); the first measured 1.93x slower end to end,
# and now measures 0.79x.
#
# Keep this bench. It is the one that distinguishes "terms() is slow" from
# "terms() is slow in this query shape", and a regression here would otherwise
# read as generic noise.
#

use strict;
use warnings;
use Time::HiRes 'time';
use URI::Escape;
use P3DataAPI;

my $url = shift || "https://alpha.bv-brc.org/api";
my @SIZES = (100, 500, 1500, 5000, 15000);

my $api = P3DataAPI->new($url);
print "endpoint: $url\n\n";

#
# Seed pools. eq/select only, so the operator under test cannot affect them.
#
my @g;
$api->query_cb("genome", sub { push(@g, map { $_->{genome_id} } @{$_[0]}); 1 },
               ["eq", "genus", "Campylobacter"],
               ["eq", "public", "true"],
               ["eq", "genome_status", "Complete"],
               ["select", "genome_id"],
               ["limit", 14]);

my (@fids, %md5);
for my $gid (sort @g)
{
    last if @fids > 16000 && keys(%md5) > 16000;
    $api->query_cb("genome_feature",
                   sub {
                       for my $e (@{$_[0]})
                       {
                           push(@fids, $e->{feature_id})    if $e->{feature_id};
                           $md5{$e->{aa_sequence_md5}} = 1  if $e->{aa_sequence_md5};
                       }
                       1;
                   },
                   ["eq", "genome_id", $gid],
                   ["eq", "annotation", "PATRIC"],
                   ["select", "feature_id,aa_sequence_md5"]);
}
my @md5 = keys %md5;
printf "pool: %d feature_ids, %d distinct aa md5\n\n", scalar @fids, scalar @md5;

#
# $run->($op, $n) must issue the query under $op and return the row count.
#
sub bench
{
    my($label, $pool, $run) = @_;

    printf "%s\n", $label;
    printf "%8s %10s %10s %8s   %s\n", "n", "in sec", "terms sec", "ratio", "rows";

    for my $n (@SIZES)
    {
        next if $n > @$pool;

        my (%best, %rows);
        for my $rep (1 .. 3)
        {
            #
            # Alternate, so neither operator is always the one running against
            # caches the other just warmed.
            #
            for my $op ($rep % 2 ? qw(in terms) : qw(terms in))
            {
                my $t0 = time;
                my $c  = eval { $run->($op, $n) };
                if ($@)
                {
                    $best{$op} = -1;
                    $rows{$op} = "DIED";
                    next;
                }
                my $el = time - $t0;
                $best{$op} = $el
                    if !defined $best{$op} || ($best{$op} > 0 && $el < $best{$op});
                $rows{$op} = $c;
            }
        }

        my $ratio = ($best{in} > 0 && $best{terms} > 0)
                        ? sprintf("%.2fx", $best{terms} / $best{in}) : "ERR";
        my $agree = (defined $rows{in} && defined $rows{terms}
                     && $rows{in} eq $rows{terms}) ? "" : "   *** MISMATCH ***";

        printf "%8d %10.2f %10.2f %8s   in=%s terms=%s%s\n",
            $n, $best{in}, $best{terms}, $ratio, $rows{in}, $rows{terms}, $agree;
    }
    print "\n";
}

#
# genome_feature: n is the real single-query value-list size.
#
bench("genome_feature / feature_id  (n = values in one query)", \@fids, sub {
    my($op, $n) = @_;
    my $vals = "(" . join(",", map { uri_escape($_) } @fids[0 .. $n - 1]) . ")";
    my $c = 0;
    $api->query_cb("genome_feature", sub { $c += scalar @{$_[0]}; 1 },
                   [$op, "feature_id", $vals],
                   ["select", "feature_id"]);
    $c;
});

#
# feature_sequence: lookup_sequence_data batches at 500 internally, so this
# varies how many 500-value queries are issued, not how big each one is. It
# honours the P3_RQL_TERMS gate rather than taking an operator argument, which
# is also what makes it the realistic client-side measurement.
#
bench("feature_sequence / md5  (n = total volume, batched 500/query)", \@md5, sub {
    my($op, $n) = @_;
    local %ENV = %ENV;
    $op eq 'terms' ? ($ENV{P3_RQL_TERMS} = 1) : delete $ENV{P3_RQL_TERMS};
    my $c = 0;
    $api->lookup_sequence_data([@md5[0 .. $n - 1]], sub { $c++ });
    $c;
});

#
# Co-occurring clause. Fixed list size, so the only thing varying is whether the
# id list shares the query with a second, low-selectivity clause -- the shape
# retrieve_protein_feature_sequence actually sends. See the header.
#
{
    my $n     = @fids < 6000 ? scalar @fids : 6000;
    my $vals  = "(" . join(",", map { uri_escape($_) } @fids[0 .. $n - 1]) . ")";
    my $type  = [ "in", "feature_type", "(mat_peptide,CDS)" ];

    printf "co-occurring clause  (n = %d, fixed)\n", $n;
    printf "%28s %10s %10s %8s   %s\n", "case", "in sec", "terms sec", "ratio", "rows";

    for my $case ([ "id list alone", undef ], [ "id list + in(feature_type)", $type ])
    {
        my (%best, %rows);
        for my $rep (1 .. 3)
        {
            for my $op ($rep % 2 ? qw(in terms) : qw(terms in))
            {
                my @q = ([ $op, "feature_id", $vals ], [ "select", "feature_id" ]);
                unshift(@q, $case->[1]) if $case->[1];

                my $c  = 0;
                my $t0 = time;
                eval { $api->query_cb("genome_feature",
                                      sub { $c += scalar @{$_[0]}; 1 }, @q); 1 }
                    or do { $best{$op} = -1; $rows{$op} = "DIED"; next };
                my $el = time - $t0;
                $best{$op} = $el
                    if !defined $best{$op} || ($best{$op} > 0 && $el < $best{$op});
                $rows{$op} = $c;
            }
        }

        printf "%28s %10.2f %10.2f %8s   in=%s terms=%s%s\n",
            $case->[0], $best{in}, $best{terms},
            (($best{in} > 0 && $best{terms} > 0)
                 ? sprintf("%.2fx", $best{terms} / $best{in}) : "ERR"),
            $rows{in}, $rows{terms},
            ((defined $rows{in} && defined $rows{terms} && $rows{in} eq $rows{terms})
                 ? "" : "   *** MISMATCH ***");
    }
    print "\n";
}
