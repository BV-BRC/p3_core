#
# Offline tests for solr_query_raw_multi: concurrency limit, user agent, and
# what happens to a query that fails in the parallel pass.
#
# HTTP::Async is replaced by a scripted fake that answers each added request
# from a queue, in reverse order to show the results are put back in query
# order. Reruns go through _solr_post and so through $api->{ua}, which is a
# scripted user agent as in p3-solr-retry.t. No network.
#
use strict;
use warnings;
use Test::More;
use HTTP::Response;
use HTTP::Headers;
use JSON::XS;

use P3DataAPI;
use P3ClientUA;

$P3ClientUA::backoff_base = 0.001;
$P3ClientUA::backoff_cap  = 0.005;

$P3DataAPI::have_async or plan skip_all => "HTTP::Async not available";

{
    package ScriptedUA;
    sub new { my($c, @r) = @_; return bless { queue => [@r], sent => [] }, $c }
    sub request
    {
        my($self, $req) = @_;
        push(@{$self->{sent}}, $req);
        my $r = shift @{$self->{queue}};
        die "ScriptedUA ran out of responses\n" unless $r;
        return $r;
    }
    sub sent { return $_[0]->{sent} }
}

sub docs_response
{
    my($tag) = @_;
    return HTTP::Response->new(200, "OK", HTTP::Headers->new("Content-Type" => "application/json"),
                               encode_json({ response => { docs => [ { tag => $tag } ] } }));
}

sub err_response
{
    my($code, $body) = @_;
    return HTTP::Response->new($code, "Err", HTTP::Headers->new("Content-Type" => "text/plain"), $body // "");
}

#
# Run solr_query_raw_multi over $nq queries. @async_responses answer the
# parallel pass, one per query in query order; @rerun_responses answer reruns.
#
sub run_multi
{
    my(%opt) = @_;
    my $nq = $opt{queries};
    my @async_responses = @{$opt{async}};
    my(%added, @order, $slots);

    no warnings 'redefine';
    local *HTTP::Async::new = sub { return bless {}, 'HTTP::Async' };
    local *HTTP::Async::DESTROY = sub { };
    local *HTTP::Async::slots = sub { $slots = $_[1] if @_ > 1; return $slots };
    local *HTTP::Async::add = sub {
        my($self, $req) = @_;
        my $id = scalar(@order) + 100;
        push(@order, $id);
        $added{$id} = $req;
        return $id;
    };
    local *HTTP::Async::not_empty = sub { return scalar @order };
    local *HTTP::Async::wait_for_next_response = sub {
        my $id = pop @order;                       # last added first
        return ($async_responses[$id - 100], $id);
    };

    my $api = P3DataAPI->new("http://example.invalid/api", "dummy-token");
    my $ua = ScriptedUA->new(@{$opt{rerun} || []});
    $api->{ua} = $ua;

    my $queries = [ map { ["genome_feature", { q => "accession:c$_" }] } 0..$nq-1 ];
    my @out = eval { $api->solr_query_raw_multi($queries) };
    return { out => \@out, err => $@, slots => $slots, added => \%added, reruns => $ua->sent };
}

#
# 1. Concurrency limit: default 2, overridable, bad values ignored.
#
{
    local $ENV{P3_DATA_API_ASYNC_SLOTS};
    local $FIG_Config::p3_data_api_async_slots;
    is(P3DataAPI->async_slots, 2, "default is 2 slots");

    $FIG_Config::p3_data_api_async_slots = 4;
    is(P3DataAPI->async_slots, 4, "FIG_Config sets the slot count");

    $ENV{P3_DATA_API_ASYNC_SLOTS} = 6;
    is(P3DataAPI->async_slots, 6, "environment overrides FIG_Config");

    my @w;
    local $SIG{__WARN__} = sub { push(@w, @_) };
    $ENV{P3_DATA_API_ASYNC_SLOTS} = "0";
    is(P3DataAPI->async_slots, 2, "zero is rejected");
    $ENV{P3_DATA_API_ASYNC_SLOTS} = "lots";
    is(P3DataAPI->async_slots, 2, "non-numeric is rejected");
    is(scalar(@w), 2, "  ... each with a warning");
}

#
# 2. All succeed: results come back in query order, the limit is applied, and
#    every request carries the P3ClientUA agent.
#
{
    local $ENV{P3_DATA_API_ASYNC_SLOTS};
    my $r = run_multi(queries => 3, async => [map { docs_response("r$_") } 0..2]);
    is($r->{err}, "", "no error");
    is_deeply([map { $_->[0]->{tag} } @{$r->{out}}], [qw(r0 r1 r2)], "results in query order");
    is($r->{slots}, 2, "async slots set to the configured limit");
    my @agents = map { $_->header("User-Agent") // "" } values %{$r->{added}};
    is(scalar(grep { $_ eq P3ClientUA::user_agent_string() } @agents), 3, "every request carries the P3ClientUA agent");
    is(scalar(@{$r->{reruns}}), 0, "no reruns");
}

#
# 3. A transient failure is rerun and its slot filled, not left undef.
#
{
    my $r = run_multi(queries => 3,
                      async => [docs_response("r0"), err_response(502, "bad gateway"), docs_response("r2")],
                      rerun => [docs_response("again1")]);
    is($r->{err}, "", "no error after a 502");
    is($r->{out}->[1]->[0]->{tag}, "again1", "502 query was rerun and its slot filled");
    is(scalar(@{$r->{reruns}}), 1, "exactly one rerun");
    like($r->{reruns}->[0]->content, qr/accession%3Ac1/, "  ... of the query that failed");
    is($r->{out}->[2]->[0]->{tag}, "r2", "other results untouched");
}

#
# 4. A 200 whose body does not decode is rerun too.
#
{
    my $r = run_multi(queries => 2,
                      async => [docs_response("r0"), HTTP::Response->new(200, "OK", HTTP::Headers->new, '{"respo')],
                      rerun => [docs_response("again1")]);
    is($r->{err}, "", "no error after a truncated body");
    is($r->{out}->[1]->[0]->{tag}, "again1", "undecodable 200 was rerun");
}

#
# 5. A permanent failure dies at once, naming the status, without a rerun.
#    This is the shape of the empty "genome_id:" query compare regions used to send.
#
{
    my $r = run_multi(queries => 2,
                      async => [docs_response("r0"), err_response(400, "Cannot parse 'genome_id:'")]);
    like($r->{err}, qr/Query failed: 400 Cannot parse 'genome_id:'/, "400 dies with the server's message");
    is(scalar(@{$r->{reruns}}), 0, "  ... and is not rerun");
}

#
# 6. A rerun that also fails dies rather than returning a hole.
#
{
    my $r = run_multi(queries => 2,
                      async => [docs_response("r0"), err_response(503, "unavailable")],
                      rerun => [err_response(400, "still bad")]);
    like($r->{err}, qr/Query failed: 400/, "failed rerun dies");
}

done_testing();
