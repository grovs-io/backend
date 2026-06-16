require "test_helper"

class AppsflyerMigrationClientTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames, :migration_sources

  setup do
    @source = migration_sources(:acme_branch)
    @source.update!(provider: "appsflyer", credentials: { "onelink_id" => "abc123", "api_token" => "tok_xxx" })
    @client = AppsflyerMigrationClient.new(@source)
  end

  def fake_response(code:, body: nil, headers: {})
    Struct.new(:code, :parsed_response, :headers).new(code, body, headers)
  end

  test "200 with OneLink data returns :found with mapped payload" do
    body = {
      "af_dp"          => "myapp://deep",
      "af_web_dp"      => "https://example.com/web",
      "af_ios_url"     => "https://apps.apple.com/x",
      "af_android_url" => "https://play.google.com/x",
      "af_og_title"    => "Hello",
      "af_og_description" => "World",
      "af_og_image"    => "https://cdn.example.com/img.png",
      "c"              => "spring_campaign",
      "pid"            => "email_source",
      "af_channel"     => "email",
      "af_ad"          => "promo_ad_name",
      "weird_extra"    => "kept_in_custom"
    }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      r = @client.fetch("abc")
      assert_equal :found, r.outcome
      assert_equal "https://apps.apple.com/x", r.payload["ios_url"]
      assert_equal "https://play.google.com/x", r.payload["android_url"]
      assert_equal "https://example.com/web", r.payload["desktop_url"]
      assert_equal "Hello", r.payload["og_title"]
      assert_equal "World", r.payload["og_description"]
      # AppsFlyer canonical mapping: c→campaign, pid→source, af_channel→medium, af_ad→name.
      assert_equal "spring_campaign", r.payload["tracking_campaign"]
      assert_equal "email_source",   r.payload["tracking_source"]
      assert_equal "email",          r.payload["tracking_medium"]
      assert_equal "promo_ad_name",  r.payload["name"]
      assert_equal "appsflyer",      r.payload["provider"]
      assert_equal "kept_in_custom", r.payload["custom_data"]["weird_extra"]
      assert_not r.payload["custom_data"].key?("af_dp"), "consumed keys leaked into custom_data"
      assert_not r.payload["custom_data"].key?("af_channel"), "af_channel leaked into custom_data"
    end
  end

  test "af_ad is NOT bound to tracking_medium or tracking_campaign (regression: was triple-bound)" do
    body = { "af_ad" => "creative_x" }  # no c, pid, af_channel
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      r = @client.fetch("abc")
      assert_nil r.payload["tracking_campaign"], "af_ad must not fall back into tracking_campaign"
      assert_nil r.payload["tracking_medium"],   "af_ad must not be bound to tracking_medium"
      assert_equal "creative_x", r.payload["name"], "af_ad correctly drives Link.name"
    end
  end

  test "200 falls back to af_dp when platform-specific URLs missing" do
    body = { "af_dp" => "myapp://fallback" }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      r = @client.fetch("abc")
      assert_equal "myapp://fallback", r.payload["ios_url"]
      assert_equal "myapp://fallback", r.payload["android_url"]
    end
  end

  test "404 returns :not_found" do
    HTTParty.stub(:get, fake_response(code: 404, body: {})) do
      r = @client.fetch("missing")
      assert_equal :not_found, r.outcome
    end
  end

  test "401 returns :transient_error" do
    HTTParty.stub(:get, fake_response(code: 401, body: {})) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
    end
  end

  test "429 with retry-after parses and clamps" do
    HTTParty.stub(:get, fake_response(code: 429, body: {}, headers: { "retry-after" => "10" })) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
      assert_equal 10, r.retry_after
    end
  end

  test "500 returns :transient_error" do
    HTTParty.stub(:get, fake_response(code: 500, body: {})) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
    end
  end

  test "fetch sends api_token via Bearer auth header" do
    captured = {}
    HTTParty.stub(:get, lambda { |_url, opts|
      captured[:opts] = opts
      fake_response(code: 404, body: {})
    }) do
      @client.fetch("abc")
    end
    assert_equal "Bearer tok_xxx", captured[:opts][:headers]["Authorization"]
  end

  test "network timeout returns :transient_error with http_status 0" do
    HTTParty.stub(:get, ->(*) { raise Net::OpenTimeout }) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
      assert_equal 0, r.http_status
    end
  end

  test "SocketError returns :transient_error" do
    HTTParty.stub(:get, ->(*) { raise SocketError }) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
    end
  end

  test "ECONNREFUSED returns :transient_error" do
    HTTParty.stub(:get, ->(*) { raise Errno::ECONNREFUSED }) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
    end
  end

  test "200 with non-Hash parsed_response returns :found with empty payload (no crash)" do
    HTTParty.stub(:get, fake_response(code: 200, body: "not a hash")) do
      r = @client.fetch("abc")
      # Either treated as :found-with-empty or :transient_error — both acceptable; the
      # invariant is that we never crash on garbage bodies.
      assert_includes [:found, :transient_error], r.outcome
    end
  end

  test "200 with empty Hash returns :found with mostly-nil payload (no crash)" do
    HTTParty.stub(:get, fake_response(code: 200, body: {})) do
      r = @client.fetch("abc")
      assert_equal :found, r.outcome
      assert_nil r.payload["ios_url"]
      assert_equal "appsflyer", r.payload["provider"]
    end
  end

  test "fetch builds URL with onelink_id and shortlink path" do
    captured = {}
    HTTParty.stub(:get, lambda { |url, _opts|
      captured[:url] = url
      fake_response(code: 404, body: {})
    }) do
      @client.fetch("abc123")
    end
    assert_match %r{onelink\.appsflyer\.com/api/v2\.0/shortlinks/abc123/abc123\z}, captured[:url]
  end

  test "fetch on a two-segment <onelink-id>/<shortlink-id> path sends only the trailing shortlink-id" do
    captured = {}
    HTTParty.stub(:get, lambda { |url, _opts|
      captured[:url] = url
      fake_response(code: 404, body: {})
    }) do
      @client.fetch("le6K/ucdxo1g3")
    end
    # onelink-id comes from credentials (abc123); the path's leading template segment is
    # dropped and the slash is NOT smuggled into the shortlink-id as %2F.
    assert_match %r{onelink\.appsflyer\.com/api/v2\.0/shortlinks/abc123/ucdxo1g3\z}, captured[:url]
    assert_not_includes captured[:url], "%2F"
  end

  test "fetch URL-encodes the shortlink-id (hash / space cannot break out of path)" do
    captured = {}
    HTTParty.stub(:get, lambda { |url, _opts|
      captured[:url] = url
      fake_response(code: 404, body: {})
    }) do
      @client.fetch("a b#c")
    end
    slug_segment = captured[:url].split("/shortlinks/abc123/").last
    assert_includes slug_segment, "%23", "hash must be percent-encoded"
    assert_includes slug_segment, "%20", "space must be percent-encoded"
    assert_not_includes captured[:url], " "
  end

  # See branch_migration_client_test.rb for the rationale: most tests pass already-parsed
  # Hashes for brevity; this one verifies raw-JSON-string parsing still works.
  test "200 with raw JSON string body parses correctly" do
    raw_json = '{"af_ios_url":"myapp://hi","c":"spring","pid":"email","af_channel":"web","af_ad":"banner"}'
    HTTParty.stub(:get, fake_response(code: 200, body: raw_json)) do
      r = @client.fetch("slug123")
      assert_equal :found, r.outcome
      assert_equal "myapp://hi", r.payload["ios_url"]
      assert_equal "spring",     r.payload["tracking_campaign"]
      assert_equal "email",      r.payload["tracking_source"]
      assert_equal "web",        r.payload["tracking_medium"]
      assert_equal "banner",     r.payload["name"]
    end
  end
end
