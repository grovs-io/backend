require "test_helper"

class BranchMigrationClientTest < ActiveSupport::TestCase
  include MigrationFixtureHelpers

  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames, :migration_sources

  setup do
    reset_acme_active_to_active!

    @source = migration_sources(:acme_branch)
    @source.update!(credentials: { "branch_key" => "key_live_xxx" })
    @client = BranchMigrationClient.new(@source)
  end

  def fake_response(code:, body: nil, headers: {})
    Struct.new(:code, :parsed_response, :headers).new(code, body, headers)
  end

  test "200 with Branch data blob returns :found with mapped payload" do
    body = {
      "data" => {
        "$ios_url"       => "myapp://ios",
        "$android_url"   => "myapp://android",
        "$desktop_url"   => "https://example.com/desktop",
        "$og_title"      => "Hello",
        "$og_description" => "World",
        "$og_image_url"  => "https://cdn.example.com/img.png",
        "~campaign"      => "spring",
        "~channel"       => "email",
        "~feature"       => "promo",
        "~tags"          => ["tag1", "tag2"],
        "custom_key"     => "custom_value"
      }
    }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      r = @client.fetch("abc")
      assert_equal :found, r.outcome
      assert_equal 200, r.http_status
      assert_equal "myapp://ios", r.payload["ios_url"]
      assert_equal "myapp://android", r.payload["android_url"]
      assert_equal "https://example.com/desktop", r.payload["desktop_url"]
      assert_equal "Hello", r.payload["og_title"]
      assert_equal "World", r.payload["og_description"]
      assert_equal "https://cdn.example.com/img.png", r.payload["og_image_url"]
      assert_equal "spring", r.payload["tracking_campaign"]
      assert_equal "email",  r.payload["tracking_source"]
      assert_equal "promo",  r.payload["tracking_medium"]
      assert_equal %w[tag1 tag2], r.payload["tags"]
      assert_equal "Hello", r.payload["name"], "name must prefer $og_title over ~feature"
      assert_equal "branch", r.payload["provider"]
      assert_equal "custom_value", r.payload["custom_data"]["custom_key"]
      assert_not r.payload["custom_data"].key?("$ios_url"), "platform URLs leaked into custom_data"
      assert_not r.payload["custom_data"].key?("$og_title"), "OG fields leaked into custom_data"
    end
  end

  test "name prefers $link_title for dashboard quick links" do
    body = { "data" => { "$link_title" => "bun-asa", "$marketing_title" => "bun-asa", "~feature" => "marketing" } }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      r = @client.fetch("abc")
      assert_equal "bun-asa", r.payload["name"]
      assert_not r.payload["custom_data"].key?("$link_title"), "title keys leaked into custom_data"
      assert_not r.payload["custom_data"].key?("$marketing_title"), "title keys leaked into custom_data"
    end
  end

  test "name falls back to ~feature when no title keys present" do
    body = { "data" => { "~feature" => "sharing" } }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      r = @client.fetch("abc")
      assert_equal "sharing", r.payload["name"]
    end
  end

  test "404 returns :not_found" do
    HTTParty.stub(:get, fake_response(code: 404, body: {})) do
      r = @client.fetch("missing")
      assert_equal :not_found, r.outcome
      assert_equal 404, r.http_status
    end
  end

  test "401 returns :transient_error with http_status" do
    HTTParty.stub(:get, fake_response(code: 401, body: {})) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
      assert_equal 401, r.http_status
    end
  end

  test "403 returns :transient_error" do
    HTTParty.stub(:get, fake_response(code: 403, body: {})) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
    end
  end

  test "429 returns :transient_error with parsed retry-after" do
    HTTParty.stub(:get, fake_response(code: 429, body: {}, headers: { "retry-after" => "30" })) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
      assert_equal 30, r.retry_after
    end
  end

  test "500 returns :transient_error" do
    HTTParty.stub(:get, fake_response(code: 500, body: {})) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
    end
  end

  test "503 returns :transient_error" do
    HTTParty.stub(:get, fake_response(code: 503, body: {})) do
      r = @client.fetch("abc")
      assert_equal :transient_error, r.outcome
    end
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

  test "200 with non-Hash body doesn't crash — returns :found with whatever can be extracted" do
    HTTParty.stub(:get, fake_response(code: 200, body: "garbage non-json")) do
      r = @client.fetch("abc")
      assert_includes [:found, :transient_error], r.outcome
    end
  end

  test "200 with valid JSON but non-Hash data does not raise TypeError" do
    %w{[] just-a-string 42 null}.each do |bad_data|
      body = { "data" => bad_data }
      HTTParty.stub(:get, fake_response(code: 200, body: body)) do
        assert_nothing_raised do
          r = @client.fetch("abc")
          assert_equal :found, r.outcome
          assert_nil r.payload["ios_url"]
        end
      end
    end
  end

  test "200 with empty body returns :found with mostly-nil payload (no crash)" do
    HTTParty.stub(:get, fake_response(code: 200, body: {})) do
      r = @client.fetch("abc")
      assert_equal :found, r.outcome
      assert_nil r.payload["ios_url"]
      assert_equal "branch", r.payload["provider"]
    end
  end

  test "probe uses a random sentinel slug (does NOT leak source.id to upstream)" do
    captured_urls = []
    HTTParty.stub(:get, lambda { |_url, opts|
      captured_urls << opts[:query][:url]
      fake_response(code: 404, body: {})
    }) do
      @client.probe
      @client.probe
    end
    captured_urls.each do |url|
      assert_match(/__grovs_setup_probe_[0-9a-f]{16}__/, url)
      assert_not_includes url, @source.id.to_s,
        "probe slug must not include the DB sequence value"
    end
    assert_not_equal captured_urls[0], captured_urls[1], "two probes must produce different slugs"
  end

  test "fetch passes query string to upstream URL" do
    captured = {}
    HTTParty.stub(:get, lambda { |_url, opts|
      captured[:opts] = opts
      fake_response(code: 404, body: {})
    }) do
      @client.fetch("abc", query_string: "utm_source=email&promo=spring")
    end
    assert_match(/\?utm_source=email&promo=spring\z/, captured[:opts][:query][:url])
  end

  test "fetch omits query string from URL when blank" do
    captured = {}
    HTTParty.stub(:get, lambda { |_url, opts|
      captured[:opts] = opts
      fake_response(code: 404, body: {})
    }) do
      @client.fetch("abc")
    end
    assert_no_match(/\?/, captured[:opts][:query][:url])
  end

  test "fetch passes branch_key in query" do
    captured = {}
    HTTParty.stub(:get, lambda { |_url, opts|
      captured[:opts] = opts
      fake_response(code: 404, body: {})
    }) do
      @client.fetch("abc")
    end
    assert_equal "key_live_xxx", captured[:opts][:query][:branch_key]
  end

  test "200 with raw JSON string body parses correctly" do
    raw_json = '{"data":{"$ios_url":"myapp://hello","~campaign":"spring"}}'
    HTTParty.stub(:get, fake_response(code: 200, body: raw_json)) do
      r = @client.fetch("abc")
      assert_equal :found, r.outcome
      assert_equal "myapp://hello", r.payload["ios_url"]
      assert_equal "spring", r.payload["tracking_campaign"]
    end
  end

  test "200 with the Branch-quirk data-as-JSON-string shape is parsed" do
    body = { "data" => '{"$ios_url":"myapp://nested","~campaign":"fall"}' }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      r = @client.fetch("abc")
      assert_equal :found, r.outcome
      assert_equal "myapp://nested", r.payload["ios_url"]
      assert_equal "fall", r.payload["tracking_campaign"]
    end
  end
end
