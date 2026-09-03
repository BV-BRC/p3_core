#
# Is the RQL terms() operator usable against a given deployment?
#
# terms(f,(a,b,c)) emits &fq={!terms f=f}a,b,c -- a hash-set match in a cached
# filter query -- where in(f,(a,b,c)) emits f:(a OR b OR c), one scored boolean
# clause per value. For the large literal id lists this module sends, terms() is
# the operator we want; P3DataAPI::id_list_op() picks between them and defaults
# to in() because as of 2026-09-03 no deployment can be trusted with terms().
#
# This test is the evidence for that default. It is a live network test against
# a deployment you name, and is skipped unless you name one:
#
#   P3_TERMS_TEST_URL=https://alpha.bv-brc.org/api perl t/client-tests/p3-rql-terms.t
#
# It answers three questions, in order:
#
#   1. Does the endpoint implement terms() at all? (production: no, HTTP 400)
#   2. Does terms() return exactly what in() returns, per affected call site?
#   3. Does terms() survive this module's real chunk_size on genome_feature?
#      (alpha: no -- limit >= 10000 truncates to a one-byte 200)
#
# All three must pass before flipping the default in id_list_op().
#

use strict;
use warnings;
use Test::More;
use Data::Dumper;
use Digest::MD5 'md5_hex';
use Time::HiRes 'time';

use P3DataAPI;

my $url = $ENV{P3_TERMS_TEST_URL};
plan skip_all => "set P3_TERMS_TEST_URL to a data API url to run this live test"
    unless $url;

my $api = P3DataAPI->new($url);

#
# id_list_op is pure environment, so check it without touching the network.
#
{
    local %ENV = %ENV;
    delete $ENV{P3_RQL_TERMS};
    is(P3DataAPI::id_list_op(), 'in', "defaults to in() with P3_RQL_TERMS unset");
    $ENV{P3_RQL_TERMS} = 1;
    is(P3DataAPI::id_list_op(), 'terms', "selects terms() with P3_RQL_TERMS=1");
}

#
# Seed data. These queries use only eq/select, so they are unaffected by the
# operator under test.
#
my @gids;
$api->query_cb("genome",
               sub { push(@gids, map { $_->{genome_id} } @{$_[0]}); 1 },
               ["eq", "genus", "Campylobacter"],
               ["eq", "public", "true"],
               ["eq", "genome_status", "Complete"],
               ["select", "genome_id"],
               ["limit", 30]);
@gids = (sort @gids)[0 .. 29] if @gids > 30;

if (!@gids)
{
    plan skip_all => "no seed genomes from $url";
}

my (@pids, @fids, %aa, %na);
$api->query_cb("genome_feature",
               sub {
                   for my $e (@{$_[0]})
                   {
                       push(@pids, $e->{patric_id})  if $e->{patric_id};
                       push(@fids, $e->{feature_id}) if $e->{feature_id};
                       $aa{$e->{aa_sequence_md5}} = 1 if $e->{aa_sequence_md5};
                       $na{$e->{na_sequence_md5}} = 1 if $e->{na_sequence_md5};
                   }
                   1;
               },
               ["eq", "genome_id", $gids[0]],
               ["eq", "feature_type", "CDS"],
               ["eq", "annotation", "PATRIC"],
               ["select", "patric_id,feature_id,aa_sequence_md5,na_sequence_md5"]);

my @aamd5 = keys %aa;
my @namd5 = keys %na;

diag(sprintf("seed from %s: %d genomes, %d patric_ids, %d feature_ids, %d aa md5, %d na md5",
             $gids[0], scalar @gids, scalar @pids, scalar @fids, scalar @aamd5, scalar @namd5));

#
# Question 1: is the operator implemented here at all? Everything below is
# meaningless if it is not, so bail out rather than emit a wall of failures.
#
{
    local $ENV{P3_RQL_TERMS} = 1;
    my @r;
    my $ok = eval {
        $api->query_cb("genome",
                       sub { push(@r, @{$_[0]}); 1 },
                       [P3DataAPI::id_list_op(), "genome_id", "(" . join(",", @gids[0 .. 4]) . ")"],
                       ["select", "genome_id"]);
        1;
    };
    my $err = $@;
    ok($ok, "terms() is implemented by $url")
        or diag("terms() failed: " . substr($err // '', 0, 200));
    if (!$ok)
    {
        diag("An 'undefined field object' 400 means the deployment's rql.js predates "
             . "terms() support. id_list_op() must stay on in() here.");
        done_testing();
        exit 0;
    }
}

#
# Question 2: per call site, does terms() return exactly what in() returns?
#
sub digest { md5_hex(join("\n", sort @{$_[0]})) }

sub compare
{
    my($name, $code) = @_;

    my (%dig, %n, %sec);
    for my $mode (qw(in terms))
    {
        local %ENV = %ENV;
        $mode eq 'terms' ? ($ENV{P3_RQL_TERMS} = 1) : delete $ENV{P3_RQL_TERMS};

        my $t0 = time;
        my $rows = eval { $code->() };
        $sec{$mode} = time - $t0;

        if ($@)
        {
            my $e = $@;
            $e =~ s/\s+/ /g;
            $dig{$mode} = "died: " . substr($e, 0, 140);
            $n{$mode}   = 'DIED';
            next;
        }
        $dig{$mode} = digest($rows);
        $n{$mode}   = scalar @$rows;
    }

    is($dig{terms}, $dig{in}, "$name: terms() matches in()")
        or diag("  in:    $n{in} rows, $dig{in}\n  terms: $n{terms} rows, $dig{terms}");

    diag(sprintf("  %-38s in %.2fs / terms %.2fs (%d rows)",
                 $name, $sec{in}, $sec{terms}, ($n{in} =~ /^\d+$/ ? $n{in} : 0)));
}

compare("retrieve_genome_metadata" => sub {
    my @r = $api->retrieve_genome_metadata(\@gids, [qw(genome_id genome_name taxon_id)]);
    [ map { join("\t", $_->{genome_id}, $_->{genome_name} // '', $_->{taxon_id} // '') } @r ];
});

compare("retrieve_protein_feature_sequence" => sub {
    my $h = $api->retrieve_protein_feature_sequence(\@pids);
    [ map { "$_\t" . length($h->{$_} // '') } keys %$h ];
});

compare("retrieve_nucleotide_feature_sequence" => sub {
    my $h = $api->retrieve_nucleotide_feature_sequence(\@pids);
    [ map { "$_\t" . length($h->{$_} // '') } keys %$h ];
});

compare("lookup_sequence_data (aa)" => sub {
    my @o;
    $api->lookup_sequence_data(\@aamd5, sub {
        my($e) = @_;
        push(@o, join("\t", $e->{md5}, $e->{sequence_type} // '', length($e->{sequence} // '')));
    });
    \@o;
});

compare("lookup_sequence_data (na)" => sub {
    my @o;
    $api->lookup_sequence_data(\@namd5, sub {
        my($e) = @_;
        push(@o, join("\t", $e->{md5}, $e->{sequence_type} // '', length($e->{sequence} // '')));
    });
    \@o;
});

#
# Question 3: the genome_feature truncation.
#
# On alpha, terms() with a limit at or above 10,000 returns a one-byte body
# ("[") under a 200 whenever the match is exhausted before the limit. chunk_size
# is 25,000, so a paged genome_feature query hits it every time. Drive it through
# query_cb at the real chunk size rather than a small one, because a small limit
# hides the bug entirely.
#
for my $mode (qw(in terms))
{
    local %ENV = %ENV;
    $mode eq 'terms' ? ($ENV{P3_RQL_TERMS} = 1) : delete $ENV{P3_RQL_TERMS};

    my @rows;
    my $ok = eval {
        $api->query_cb("genome_feature",
                       sub { push(@rows, @{$_[0]}); 1 },
                       [P3DataAPI::id_list_op(), "feature_id",
                        "(" . join(",", @fids) . ")"],
                       ["select", "feature_id"]);
        1;
    };
    my $err = $@;

    is(scalar @rows, scalar @fids,
       "genome_feature/$mode at chunk_size returns all " . scalar(@fids) . " rows")
        or diag($ok ? "  returned " . scalar(@rows) . " rows -- short read taken for success"
                    : "  died: " . substr(($err // '') =~ s/\s+/ /gr, 0, 160));
}

done_testing();
