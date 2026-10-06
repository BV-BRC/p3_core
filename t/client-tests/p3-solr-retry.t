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

#
# The schema lookup behind cursor paging. It is a prerequisite of every cursor
# query, so an unretried transient here fails whatever the caller was doing --
# a single 502 on this ~200-byte GET aborted a completed 217-genome BLAST
# database build (Tectiviridae, 2026-09-02) after all its real work was done.
#

sub schema_response
{
    my($key) = @_;
    return ok_response(encode_json({ schema => { uniqueKey => $key } }));
}

#
# 16. A transient 502 on the schema endpoint is retried, not fatal.
#
{
    my($api, $ua) = api_with(err_response(502, "Bad Gateway", "error code: 502"),
                             schema_response("genome_id"));
    my $key = $api->_unique_key_for_core("genome");
    is($ua->attempts, 2, "_unique_key_for_core retries a 502");
    is($key, "genome_id", "  ... and returns the discovered key");
}

#
# 17. The result is memoized, so a paging loop costs one request no matter how
#     many pages it walks.
#
{
    my($api, $ua) = api_with(schema_response("feature_id"));
    is($api->_unique_key_for_core("genome_feature"), "feature_id", "first lookup fetches");
    is($api->_unique_key_for_core("genome_feature"), "feature_id", "second lookup is cached");
    is($ua->attempts, 1, "  ... with only one request made");
}

#
# 18. Staying unreachable for the whole budget is still fatal. The plan's
#     requirement is to fail out rather than quietly resume deep paging, and
#     retrying must not soften that into a silent fallback.
#
#     A UA that never stops failing, rather than a scripted queue: the number of
#     attempts inside the budget is a function of jittered backoff and so is not
#     fixed, and a queue that runs dry would report as its own error.
{
    package AlwaysFailsUA;
    sub new { return bless { sent => 0 }, shift }
    sub request
    {
        my($self) = @_;
        $self->{sent}++;
        return HTTP::Response->new(502, "Bad Gateway", HTTP::Headers->new(), "");
    }
    sub attempts { return $_[0]->{sent} }
}
{
    local $ENV{P3_HTTP_RETRY_MAX_ELAPSED} = 0.05;
    my $api = P3DataAPI->new("http://example.invalid/api", "dummy-token");
    my $ua = AlwaysFailsUA->new;
    $api->{ua} = $ua;

    eval { $api->_unique_key_for_core("genome") };
    like($@, qr/cannot determine the uniqueKey for core 'genome'/,
         "_unique_key_for_core dies when the endpoint stays down");
    like($@, qr/silently duplicated and dropped rows/, "  ... explaining why that is fatal");
    cmp_ok($ua->attempts, '>', 1, "  ... having actually retried first");
}

#
# 19. A 400 means this core has no schema endpoint; asking again cannot change
#     that, so it fails on the first attempt.
#
{
    my($api, $ua) = api_with(err_response(400, "Bad Request", ""));
    eval { $api->_unique_key_for_core("nosuchcore") };
    like($@, qr/cannot determine the uniqueKey/, "a 400 is fatal");
    is($ua->attempts, 1, "  ... without retrying");
}

#
# 20. A reachable core that reports no uniqueKey is a different failure from an
#     unreachable one, and says so.
#
{
    my($api, $ua) = api_with(ok_response(encode_json({ schema => {} })));
    eval { $api->_unique_key_for_core("genome") };
    like($@, qr/reports no uniqueKey/, "a schema without a uniqueKey is fatal");
    is($ua->attempts, 1, "  ... and is not retried, since the answer will not change");
}

#
# 21. A 200 whose body is not a schema is a transient, not a verdict about the
#     schema.
#
#     Every test above this point feeds the schema path a well-formed body, and
#     that is how the real bug shipped: classify_response calls any 2xx NO_RETRY,
#     so a 200 carrying an empty body, a truncated one, or an edge's HTML error
#     page went straight to "core 'x' reports no uniqueKey" on the first attempt
#     -- a confident statement about the schema, made from a body that never
#     contained one. It failed a GenomeAnnotation job on core 'taxonomy'
#     (2026-10-05) whose schema has had taxon_id throughout.
#
#     detect_truncated_body cannot cover this: it needs a Content-Length to
#     compare against and the API serves this endpoint chunked.
#
#     Note test 15 already required exactly this of submit_query. The schema
#     lookup was inconsistent with its own sibling.
#
{
    my @bad = (
        ["a truncated body",  '{"schema":{"uniqueKey":"genome_'],
        ["an empty body",     ''],
        ["an HTML error page", '<html><body>502 Bad Gateway</body></html>'],
    );

    for my $c (@bad)
    {
        my($what, $body) = @$c;
        my($api, $ua) = api_with(ok_response($body), schema_response("genome_id"));
        my $key = eval { $api->_unique_key_for_core("genome") };
        is($key, "genome_id", "_unique_key_for_core recovers from $what");
        is($ua->attempts, 2, "  ... by retrying it rather than believing it");
    }
}

#
# A user agent that keeps returning the same response, for the cases where the
# endpoint never recovers. ScriptedUA dies when its queue empties, which is the
# right guard for a fixed script but would mask the error under test here: the
# retry count is driven by the elapsed budget, not by a number we can predict.
# These blocks bound the budget instead.
#
{
    package RepeatUA;
    sub new { my($c, $r) = @_; return bless { res => $r, n => 0 }, $c }
    sub request { my($self) = @_; $self->{n}++; return $self->{res} }
    sub attempts { return $_[0]->{n} }
}

sub api_repeating
{
    my($res) = @_;
    my $api = P3DataAPI->new("http://example.invalid/api", "dummy-token");
    my $ua = RepeatUA->new($res);
    $api->{ua} = $ua;
    return ($api, $ua);
}

#
# 22. When such a body is all the endpoint ever returns, the failure names what
#     was actually received instead of blaming the schema.
#
{
    local $P3ClientUA::default_max_elapsed = 0.05;
    my($api, $ua) = api_repeating(ok_response('<html><body>502 Bad Gateway</body></html>'));
    eval { $api->_unique_key_for_core("genome") };
    my $err = $@;

    like($err, qr/cannot determine the uniqueKey/,
         "an endlessly unusable body reports as undeterminable");
    unlike($err, qr/reports no uniqueKey/,
           "  ... and never claims the schema lacks the key");
    like($err, qr/body is not JSON/, "  ... says the body would not parse");
    like($err, qr/502 Bad Gateway/, "  ... and quotes what came back");
    cmp_ok($ua->attempts, '>', 1, "  ... after more than one attempt");
}

#
# 23. The evidence in the message distinguishes the cases a reader cannot
#     reproduce, since by the time anyone looks the transient is gone.
#
{
    local $P3ClientUA::default_max_elapsed = 0.05;
    my($api, $ua) = api_repeating(ok_response(''));
    eval { $api->_unique_key_for_core("genome") };
    like($@, qr/0 bytes/, "an empty body is reported as 0 bytes");
}

#
# 24. A well-formed document that genuinely lacks the key keeps the old
#     behaviour: one attempt, and a message entitled to talk about the schema.
#     Retrying this would spend the entire elapsed budget on an answer that
#     cannot change -- the distinction test 21 must not erase.
#
{
    my($api, $ua) = api_with(ok_response(encode_json({ schema => { fields => [] } })));
    eval { $api->_unique_key_for_core("genome") };
    like($@, qr/reports no uniqueKey/, "a parsed schema with no uniqueKey still says so");
    like($@, qr/parsed as JSON/, "  ... and notes that the body was well-formed");
    is($ua->attempts, 1, "  ... without retrying");
}

done_testing();
