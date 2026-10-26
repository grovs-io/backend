require "test_helper"

class EventStream::Adapters::WebhookTest < ActiveSupport::TestCase
  include EventStreamTestHelper
  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @dest = EventDestination.new(project: projects(:one), name: "w", kind: "webhook", settings: { "url" => "https://hooks.example.com/in" }, batch_size: 2)
    @dest.generate_signing_secret
    @dest.credentials_hash = { "headers" => { "X-Api-Key" => "k1" } }
    @dest.save!
    @bodies = (1..5).map { |i| { schema_version: 1, id: "e#{i}", type: "install" } }
  end

  def ok = Struct.new(:code, :body).new(200, "")
  def failed = Struct.new(:code, :body).new(500, "nope")

  test "posts NDJSON chunks of batch_size with signature and custom headers" do
    calls = []
    capture = lambda do |url, opts|
      calls << [url, opts]
      ok
    end
    HTTParty.stub(:post, capture) do
      accepted, error = EventStream::Adapters::Webhook.new(@dest).deliver(@bodies)
      assert_equal 5, accepted
      assert_nil error
    end
    assert_equal 3, calls.size
    url, opts = calls.first
    assert_equal "https://hooks.example.com/in", url
    lines = opts[:body].split("\n")
    assert_equal 2, lines.size
    assert_equal "e1", JSON.parse(lines.first)["id"]
    assert_equal "application/x-ndjson", opts[:headers]["Content-Type"]
    assert_equal "k1", opts[:headers]["X-Api-Key"]
    assert_equal @dest.hashid, opts[:headers]["X-Grovs-Destination"]
    sig = opts[:headers]["X-Grovs-Signature"]
    t = sig[/t=(\d+)/, 1]
    assert_equal "t=#{t},v1=#{EventStream::Adapters::Webhook.signature(@dest.signing_secret, t, opts[:body])}", sig
    assert_equal false, opts[:follow_redirects]
    assert opts[:stream_body]
    assert_equal EventStream::PinnedConnection, opts[:connection_adapter]
    assert_equal({ ipaddr: "203.0.113.10" }, opts[:connection_adapter_options])
    assert_equal 10, opts[:open_timeout]
    assert_equal 30, opts[:read_timeout]
  end

  test "stops at the first failed chunk and reports the accepted prefix" do
    n = 0
    HTTParty.stub(:post, ->(*) { (n += 1) == 2 ? failed : ok }) do
      accepted, error = EventStream::Adapters::Webhook.new(@dest).deliver(@bodies)
      assert_equal 2, accepted
      assert_match(/500/, error)
    end
  end

  test "network exceptions count as failure of that chunk" do
    HTTParty.stub(:post, ->(*) { raise Net::OpenTimeout, "t/o" }) do
      accepted, error = EventStream::Adapters::Webhook.new(@dest).deliver(@bodies)
      assert_equal 0, accepted
      assert_match(/OpenTimeout/, error)
    end
  end

  test "a destination resolving to a private address is refused before any request" do
    with_resolver(["169.254.169.254"]) do
      HTTParty.stub(:post, ->(*) { flunk "must not connect" }) do
        accepted, error = EventStream::Adapters::Webhook.new(@dest).deliver(@bodies)
        assert_equal 0, accepted
        assert_match(/private/, error)
      end
    end
  end

  test "the pinned connection dials the vetted address but keeps the hostname for TLS" do
    http = EventStream::PinnedConnection.call(URI("https://hooks.example.com/in"), connection_adapter_options: { ipaddr: "203.0.113.10" })
    assert_equal "203.0.113.10", http.ipaddr
    assert_equal "hooks.example.com", http.address
    assert http.use_ssl?
  end

  test "a huge error response is never buffered and never reaches the error text" do
    huge = lambda do |_url, _opts, &block|
      1000.times { block.call("x" * 1024) }
      Struct.new(:code, :body).new(500, nil)
    end
    HTTParty.stub(:post, huge) do
      accepted, error = EventStream::Adapters::Webhook.new(@dest).deliver(@bodies.first(1))
      assert_equal 0, accepted
      assert_equal "HTTP 500", error, "the remote body must stay in the log, never in last_error"
    end
  end

  test "each request is capped by a total deadline, not just per read" do
    seen = nil
    Timeout.stub(:timeout, lambda { |seconds, &block|
      seen = seconds
      block.call
    }) do
      HTTParty.stub(:post, ->(*) { ok }) { EventStream::Adapters::Webhook.new(@dest).deliver(@bodies.first(1)) }
    end
    assert_equal EventStream::Adapters::Webhook::TOTAL_TIMEOUT, seen
  end
end
