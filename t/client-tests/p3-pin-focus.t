#
# Offline tests for how compare regions finds the focus feature of a pin.
#
# get_pin_p3 used to take the focus feature's row ($me) only from the family
# member list. members_of_family caps that list, and cursor paging orders it by
# feature_id unless a sort is given, so in a large family the focus feature was
# usually cut off. $me came back undef and compare_regions_for_peg later died
# with a Solr syntax error on an empty "genome_id:".
#
# The Solr calls are replaced at the method level; nothing touches the network.
#
use strict;
use warnings;
use Test::More;

use P3DataAPI;

my $focus = "fig|1.1.peg.5";

my %focus_row = (patric_id => $focus, genome_id => "1.1", accession => "c1",
                 start => 900, end => 100, strand => "-", aa_sequence_md5 => "m5");

sub member
{
    my($n) = @_;
    return { patric_id => "fig|2.$n.peg.1", genome_id => "2.$n", accession => "a$n",
             start => 1, end => 300, strand => "+", aa_sequence_md5 => "x$n" };
}

#
# Install fakes for the two Solr entry points get_pin_p3 reaches, recording the
# calls made. $family is what family_of sees; $members is what the family query
# returns; $direct is what a direct patric_id lookup of the focus feature returns.
#
sub with_fakes
{
    my(%opt) = @_;
    my @calls;
    no warnings 'redefine';
    local *P3DataAPI::solr_query = sub {
        my($self, $core, $q) = @_;
        push(@calls, [solr_query => $q]);
        if ($q->{fl} && $q->{fl} !~ /,/)
        {
            # family_of: a single-field lookup
            return defined($opt{family}) ? [{ $q->{fl} => $opt{family} }] : [];
        }
        return [ map { { %$_ } } @{$opt{direct}} ];
    };
    local *P3DataAPI::solr_query_list = sub {
        my($self, $core, $q, $max) = @_;
        push(@calls, [solr_query_list => { @$q }, $max]);
        return [ map { { %$_ } } @{$opt{members}} ];
    };
    my $api = P3DataAPI->new("http://example.invalid/api", "dummy-token");
    my @res = eval { $api->get_pin_p3($focus, "pgfam", 10) };
    return { res => \@res, err => $@, calls => \@calls };
}

#
# 1. The family query asks for relevance order, so the focus feature (which
#    matches both clauses of the query) sorts first and survives the cut.
#
{
    my $r = with_fakes(family => "PGF_1", members => [\%focus_row, map { member($_) } 1..3]);
    my($list) = grep { $_->[0] eq 'solr_query_list' } @{$r->{calls}};
    ok($list, "family member query was made");
    is($list->[1]->{sort}, "score desc", "family query sorts by relevance");
    like($list->[1]->{q}, qr/^pgfam_id:PGF_1 OR patric_id:\Q$focus\E$/, "query covers family and focus feature");
}

#
# 2. Focus feature present in the member list: it is $me, the others are the
#    pin, and no extra lookup is made.
#
{
    my $r = with_fakes(family => "PGF_1", members => [\%focus_row, map { member($_) } 1..3]);
    is($r->{err}, "", "no error");
    my($me, @pin) = @{$r->{res}};
    is($me->{patric_id}, $focus, "focus feature taken from the member list");
    is(scalar(@pin), 3, "the other members form the pin");
    my $direct = grep { $_->[0] eq 'solr_query' && $_->[1]->{q} =~ /patric_id:"/ } @{$r->{calls}};
    is($direct, 0, "no direct lookup when the focus feature was in the list");
}

#
# 3. The regression: the focus feature is not in the (capped) member list. It is
#    fetched directly, with minus-strand coordinates swapped like the members'.
#
{
    my $r = with_fakes(family => "PGF_1", members => [map { member($_) } 1..10],
                       direct => [\%focus_row]);
    is($r->{err}, "", "no error");
    my($me, @pin) = @{$r->{res}};
    ok($me, "focus feature found although it was missing from the member list");
    is($me->{patric_id}, $focus, "  ... and it is the right feature");
    is($me->{genome_id}, "1.1", "  ... with a genome id for genes_in_region_bulk");
    is_deeply([$me->{start}, $me->{end}], [100, 900], "  ... minus-strand start/end swapped");
    is(scalar(@pin), 10, "pin is the full member list");
}

#
# 4. The focus feature cannot be found at all (e.g. private genome, no token):
#    die with a message naming it, rather than carrying on with an empty row.
#
{
    my $r = with_fakes(family => "PGF_1", members => [map { member($_) } 1..3], direct => []);
    like($r->{err}, qr/feature \Q$focus\E was not found/, "missing focus feature is a clear error");
}

#
# 5. No family: the focus feature's own row comes back via the same lookup.
#
{
    my $r = with_fakes(family => undef, direct => [\%focus_row]);
    is($r->{err}, "", "no error");
    my($me, @pin) = @{$r->{res}};
    is($me->{patric_id}, $focus, "no-family case returns the focus feature");
    is_deeply([$me->{start}, $me->{end}], [100, 900], "  ... minus-strand start/end swapped");
    is(scalar(@pin), 0, "  ... and no pin");
}

done_testing();
