#
# Offline tests for the retry behaviour of the raw solr query path.
#
# Everything here runs against a scripted user agent -- no network, no token,
# no service. The backoff constants are stamped down to milliseconds so the
# whole file runs in well under a second; without that, the real schedule
# (exponential from 1s with full jitter) would make this take minutes.
#
use strict;
use warnings;
use Test::More;
use HTTP::Response;
use HTTP::Headers;

use P3DataAPI;
use P3ClientUA;
use JSON::XS;

$P3ClientUA::backoff_base = 0.001;
$P3ClientUA::backoff_cap  = 0.005;

#
# A user agent that hands back a scripted list of responses and records the
# requests it was given. Each ->request pops the next scripted response, so the
# count of recorded requests is exactly the number of attempts made.
#
{
    package ScriptedUA;
    sub new { my($c, @r) = @_; return bless { queue => [@r], sent => [] }, $c }
    sub request
    {
        my($self, $req) = @_;
        push(@{$self->{sent}}, $req);
        my $r = shift @{$self->{queue}};
        die "ScriptedUA ran out of responses after " . scalar(@{$self->{sent}}) . " requests\n"
            unless $r;
        return $r;
    }
    sub attempts { return scalar @{$_[0]->{sent}} }
    sub sent { return $_[0]->{sent} }
}

sub ok_response
{
    my($body) = @_;
    $body = encode_json({ response => { numFound => 1, docs => [ { genome_id => "83332.12" } ] } })
        unless defined $body;
    my $r = HTTP::Response->new(200, "OK", HTTP::Headers->new("Content-Type" => "application/json"), $body);
    return $r;
}

sub err_response
{
    my($code, $msg, $body, @hdr) = @_;
    return HTTP::Response->new($code, $msg, HTTP::Headers->new(@hdr), $body // "");
}

sub api_with
{
    my(@responses) = @_;
    my $api = P3DataAPI->new("http://example.invalid/api", "dummy-token");
    my $ua = ScriptedUA->new(@responses);
    $api->{ua} = $ua;
    return ($api, $ua);
}

#
# 1. A transient 502 is retried and the call then succeeds. This is the exact
#    shape that killed the Coronaviridae BLAST build.
#
{
    my($api, $ua) = api_with(err_response(502, "Bad Gateway"), ok_response());
    my $out = eval { $api->solr_query_raw_list("genome", [q => "*:*"]) };
    is($@, '', "502 then 200 does not die");
    is($ua->attempts, 2, "  ... after exactly one retry");
    is($out->{response}{numFound}, 1, "  ... and returns the decoded body");
}

#
# 2. Each attempt is a freshly built request. A replayed HTTP::Request with a
#    content queue streams zero bytes on the second send, so this is the
#    property the factory exists to guarantee.
#
{
    my($api, $ua) = api_with(err_response(503, "Service Unavailable"), ok_response());
    $api->solr_query_raw_list("genome", [q => "*:*", fq => "public:true"]);
    my($first, $second) = @{$ua->sent};
    isnt($first, $second, "each attempt is a distinct request object");
    is($first->content, $second->content, "  ... carrying identical bodies");
    like($first->content, qr/fq=public/, "  ... with the filter query intact");
}

#
# 3. Repeated fq keys survive. Every filter the BLAST builder adds is another
#    fq, so collapsing them would silently change what gets built.
#
{
    my($api, $ua) = api_with(ok_response());
    $api->solr_query_raw_list("genome", [q => "*:*", fq => "a:1", fq => "b:2"]);
    is($ua->sent->[0]->content, "q=*%3A*&fq=a%3A1&fq=b%3A2", "duplicate fq keys are preserved");
}

#
# 4. A 400 is the service rejecting the query. Repeating it changes nothing.
#
{
    my($api, $ua) = api_with(err_response(400, "Bad Request", "undefined field bogus"));
    eval { $api->solr_query_raw_list("genome", [q => "*:*"]) };
    like($@, qr/Query failed: 400/, "a 400 dies");
    is($ua->attempts, 1, "  ... without retrying");
}

#
# 5. A Cloudflare 1010 is a policy decision, not a hiccup -- the edge will make
#    the same decision again. The RQL path's habit of retrying it fifteen times
#    over ~135s is exactly what must not be reproduced here.
#
{
    my($api, $ua) = api_with(err_response(403, "Forbidden",
                                          '{"error_code":1010,"cloudflare_error":true,"retryable":false}',
                                          "Content-Type" => "application/json",
                                          "CF-Ray" => "8f00000000000000-ORD"));
    eval { $api->solr_query_raw_list("genome", [q => "*:*"]) };
    isnt($@, '', "a 1010 dies");
    is($ua->attempts, 1, "  ... without retrying");
}

#
# 6. A body cut short mid-transfer arrives as a 200. classify_response
#    short-circuits on is_success, so this is only retryable because the send
#    hook turns it into a failure.
#
{
    my $full = encode_json({ response => { numFound => 1, docs => [] } });
    my $short = HTTP::Response->new(200, "OK",
                                    HTTP::Headers->new("Content-Type" => "application/json",
                                                       "Content-Length" => length($full) + 500),
                                    $full);
    my($api, $ua) = api_with($short, ok_response());
    my $out = eval { $api->solr_query_raw_list("genome", [q => "*:*"]) };
    is($@, '', "a truncated 200 does not die");
    is($ua->attempts, 2, "  ... it is retried");
    is($out->{response}{numFound}, 1, "  ... and the good body is returned");
}

#
# 7. A 200 carrying something that is not JSON is a broken response, not an
#    answer. Retried, then reported -- never returned as success.
#
{
    my($api, $ua) = api_with(ok_response("<html>error page</html>"), ok_response());
    my $out = eval { $api->solr_query_raw_list("genome", [q => "*:*"]) };
    is($@, '', "an unparseable 200 does not die when the retry succeeds");
    is($ua->attempts, 2, "  ... it is retried");
    is($out->{response}{numFound}, 1, "  ... and the good body is returned");
}

#
# 8. P3_HTTP_RETRY_DISABLE exists so a caller can observe a fault rather than
#    survive it.
#
{
    local $ENV{P3_HTTP_RETRY_DISABLE} = 1;
    my($api, $ua) = api_with(err_response(502, "Bad Gateway"), ok_response());
    eval { $api->solr_query_raw_list("genome", [q => "*:*"]) };
    like($@, qr/Query failed: 502/, "P3_HTTP_RETRY_DISABLE surfaces the failure");
    is($ua->attempts, 1, "  ... on the first attempt");
}

#
# 9. The wall-clock budget bounds a service that is simply down, rather than
#    letting one page hang a build forever.
#
{
    local $ENV{P3_HTTP_RETRY_MAX_ELAPSED} = 0;
    my($api, $ua) = api_with(err_response(503, "Service Unavailable"), ok_response());
    eval { $api->solr_query_raw_list("genome", [q => "*:*"]) };
    like($@, qr/Query failed: 503/, "an exhausted budget reports the last failure");
    is($ua->attempts, 1, "  ... having stopped rather than sleeping past the deadline");
}

#
# 10. solr_query_raw takes a hash rather than a list, and shares the same path.
#
{
    my($api, $ua) = api_with(err_response(504, "Gateway Timeout"), ok_response());
    my $out = eval { $api->solr_query_raw("genome", { q => "*:*" }) };
    is($@, '', "solr_query_raw retries too");
    is($ua->attempts, 2, "  ... once");
    is($out->{response}{numFound}, 1, "  ... returning the decoded body");
}

#
# submit_query is the RQL path. It shares the helper now, so the contrast that
# matters is with what it used to do on its own: fifteen retries of anything,
# including responses that could never come back different.
#

#
# 11. A transient failure is still survived.
#
{
    my($api, $ua) = api_with(err_response(503, "Service Unavailable"), ok_response());
    my($resp, $data) = $api->submit_query("genome", "q=*:*");
    ok($resp && $resp->is_success, "submit_query survives a 503");
    is($ua->attempts, 2, "  ... after one retry");
    is($data->{response}{numFound}, 1, "  ... and hands back the decoded body");
}

#
# 12. The 1010 wart: the old loop spent ~135s repeating a response the edge had
#     marked retryable:false.
#
{
    my($api, $ua) = api_with(err_response(403, "Forbidden",
                                          q<{"error_code":1010,"cloudflare_error":true,"retryable":false}>,
                                          "Content-Type" => "application/json",
                                          "CF-Ray" => "8f00000000000000-ORD"));
    eval { $api->submit_query("genome", "q=*:*") };
    isnt($@, q<>, "submit_query dies on a 1010");
    is($ua->attempts, 1, "  ... on the first attempt, no longer fifteen");
    like($@, qr/query = /, "  ... and still reports the query text");
}

#
# 13. A rejected query cannot become valid by being asked again.
#
{
    my($api, $ua) = api_with(err_response(400, "Bad Request", "undefined field bogus"));
    eval { $api->submit_query("genome", "q=bogus:1") };
    like($@, qr/Failed: 400/, "submit_query dies on a 400");
    is($ua->attempts, 1, "  ... without retrying");
}

#
# 14. A genuine 500 from the origin is the origin struggling. Hammering it
#     fifteen times is how a slow outage becomes a hard one.
#
{
    my($api, $ua) = api_with(err_response(500, "Internal Server Error", "boom"));
    eval { $api->submit_query("genome", "q=*:*") };
    like($@, qr/Failed: 500/, "submit_query dies on an origin 500");
    is($ua->attempts, 1, "  ... without retrying");
}

#
# 15. A body that will not parse is retried rather than dying with a decode
#     error, which is what the old loop did too -- the one retry behaviour
#     worth keeping.
#
{
    my($api, $ua) = api_with(ok_response("not json at all"), ok_response());
    my($resp, $data) = $api->submit_query("genome", "q=*:*");
    is($ua->attempts, 2, "submit_query retries an undecodable body");
    is($data->{response}{numFound}, 1, "  ... and returns the good one");
}

done_testing();
