require "test_helper"

class EventStream::Adapters::S3Test < ActiveSupport::TestCase
  include EventStreamTestHelper
  fixtures :instances, :users, :instance_roles, :projects

  FakeClient = Struct.new(:puts, :fail_with) do
    def put_object(**args)
      raise fail_with if fail_with

      puts << args
    end
  end

  setup do
    @dest = EventDestination.new(project: projects(:one), name: "lake", kind: "s3",
                                 settings: { "bucket" => "acme-events", "region" => "eu-central-1", "prefix" => "grovs" })
    @dest.credentials_hash = { "access_key_id" => "AKIA", "secret_access_key" => "s" }
    @dest.save!
    @bodies = [{ schema_version: 1, id: "e1", type: "install", occurred_at: "2026-09-15T10:03:11.412Z" },
               { schema_version: 1, id: "e2", type: "app_open", occurred_at: "2026-09-15T10:04:00.000Z" }]
  end

  test "writes one gzip ndjson object under project/date partitions" do
    client = FakeClient.new([], nil)
    EventStream::Adapters::S3.stub(:build_client, client) do
      accepted, error = EventStream::Adapters::S3.new(@dest).deliver(@bodies)
      assert_equal 2, accepted
      assert_nil error
    end
    put = client.puts.first
    assert_equal "acme-events", put[:bucket]
    assert_match %r{\Agrovs/project=#{projects(:one).hashid}/date=2026-09-15/\d+-e1\.ndjson\.gz\z}, put[:key]
    assert_equal "application/x-ndjson", put[:content_type]
    assert_equal "gzip", put[:content_encoding]
    lines = Zlib::GzipReader.new(StringIO.new(put[:body])).read.split("\n")
    assert_equal %w[e1 e2], lines.map { |l| JSON.parse(l)["id"] }
  end

  test "failure returns zero accepted with the error" do
    client = FakeClient.new([], Aws::S3::Errors::AccessDenied.new(nil, "denied"))
    EventStream::Adapters::S3.stub(:build_client, client) do
      accepted, error = EventStream::Adapters::S3.new(@dest).deliver(@bodies)
      assert_equal 0, accepted
      assert_match(/AccessDenied/, error)
    end
  end

  test "build_client uses stored keys when present, otherwise the default chain, and honours endpoint" do
    @dest.credentials_hash = { "access_key_id" => "AKIA", "secret_access_key" => "s" }
    @dest.settings = @dest.settings.merge("endpoint" => "http://minio:9000", "force_path_style" => true)
    client = with_self_hosted { EventStream::Adapters::S3.build_client(@dest) }
    assert_equal 0, client.config.retry_limit
    assert_equal "http://minio:9000", client.config.endpoint.to_s
    assert client.config.force_path_style
    assert_equal "AKIA", client.config.credentials.credentials.access_key_id
  end

  test "without keys the deployment's credentials are refused on SaaS and allowed self-hosted" do
    @dest.credentials_hash = nil
    assert_raises(ArgumentError) { EventStream::Adapters::S3.build_client(@dest) }
    with_self_hosted { assert_kind_of Aws::S3::Client, EventStream::Adapters::S3.build_client(@dest) }
  end

  test "a custom endpoint resolving to a private address is refused at send time on SaaS" do
    @dest.settings = @dest.settings.merge("endpoint" => "https://internal.example.com")
    with_resolver(["169.254.169.254"]) do
      assert_raises(ArgumentError) { EventStream::Adapters::S3.build_client(@dest) }
    end
  end

  test "on SaaS custom public HTTPS S3 providers are accepted" do
    @dest.settings = @dest.settings.merge("endpoint" => "https://s3.eu-central-1.wasabisys.com")
    assert_equal "https://s3.eu-central-1.wasabisys.com", EventStream::Adapters::S3.build_client(@dest).config.endpoint.to_s
    %w[https://fsn1.your-objectstorage.com https://storage.custom-provider.example].each do |endpoint|
      @dest.settings = @dest.settings.merge("endpoint" => endpoint)
      assert_equal endpoint, EventStream::Adapters::S3.build_client(@dest).config.endpoint.to_s
    end
    @dest.settings = @dest.settings.merge("endpoint" => "http://storage.custom-provider.example")
    assert_raises(ArgumentError) { EventStream::Adapters::S3.build_client(@dest) }
  end

  test "custom uploads pin the final virtual bucket host and preserve TLS verification" do
    @dest.settings = @dest.settings.merge("endpoint" => "https://storage.custom-provider.example")
    client = EventStream::Adapters::S3.build_client(@dest)
    http = Net::HTTP.new("acme-events.storage.custom-provider.example", 443, nil)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-length"] = "0"
    sent = []
    response.stub(:read_body, ->(&block) {}) do
      http.stub(:start, ->(&block) { block.call(http) }) do
        http.stub(:request, lambda { |request, &block|
          sent << request
          block.call(response)
        }) do
          Net::HTTP.stub(:new, lambda { |host, port, proxy|
            assert_equal "acme-events.storage.custom-provider.example", host
            assert_equal 443, port
            assert_nil proxy
            http
          }) { client.put_object(bucket: "acme-events", key: "events.gz", body: "data") }
        end
      end
    end
    assert_equal "203.0.113.10", http.ipaddr
    assert http.use_ssl?
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal 0, http.max_retries
    assert_equal "acme-events.storage.custom-provider.example", sent.first["host"]
  end

  test "uploads refuse private bucket hostnames even when the base endpoint is public" do
    @dest.settings = @dest.settings.merge("endpoint" => "https://storage.custom-provider.example")
    client = EventStream::Adapters::S3.build_client(@dest)
    previous = EventStream::HostGuard.resolver
    EventStream::HostGuard.resolver = lambda do |host|
      host.start_with?("acme-events.") ? ["169.254.169.254"] : ["203.0.113.10"]
    end
    Net::HTTP.stub(:new, ->(*) { flunk "Blocked hosts must not open a connection" }) do
      assert_raises(EventStream::HostGuard::Blocked) do
        client.put_object(bucket: "acme-events", key: "events.gz", body: "data")
      end
    end
  ensure
    EventStream::HostGuard.resolver = previous
  end

  test "cached clients recheck DNS before each upload" do
    @dest.settings = @dest.settings.merge("endpoint" => "https://storage.custom-provider.example", "force_path_style" => true)
    client = EventStream::Adapters::S3.build_client(@dest)
    with_resolver(["127.0.0.1"]) do
      Net::HTTP.stub(:new, ->(*) { flunk "Blocked hosts must not open a connection" }) do
        assert_raises(EventStream::HostGuard::Blocked) do
          client.put_object(bucket: "acme-events", key: "events.gz", body: "data")
        end
      end
    end
  end

  test "uploads reject unspecified IPv6 DNS answers before opening a connection" do
    @dest.settings = @dest.settings.merge("endpoint" => "https://storage.custom-provider.example")
    client = EventStream::Adapters::S3.build_client(@dest)
    [["::"], ["0:0:0:0:0:0:0:0"], ["203.0.113.10", "::"]].each do |addresses|
      with_resolver(addresses) do
        Net::HTTP.stub(:new, ->(*) { flunk "Unspecified addresses must not open a connection" }) do
          assert_raises(EventStream::HostGuard::Blocked) do
            client.put_object(bucket: "acme-events", key: "events.gz", body: "data")
          end
        end
      end
    end
  end

  test "a batch spanning two event dates writes one object per date" do
    bodies = @bodies + [{ schema_version: 1, id: "e3", type: "install", occurred_at: "2026-09-16T00:00:01.000Z" }]
    client = FakeClient.new([], nil)
    EventStream::Adapters::S3.stub(:build_client, client) do
      assert_equal [3, nil], EventStream::Adapters::S3.new(@dest).deliver(bodies)
    end
    assert_equal %w[date=2026-09-15 date=2026-09-16], client.puts.map { |put| put[:key][/date=[\d-]+/] }
  end

  test "each upload is capped by a total deadline, not just per read" do
    seen = nil
    Timeout.stub(:timeout, lambda { |seconds, &block|
      seen = seconds
      block.call
    }) do
      EventStream::Adapters::S3.stub(:build_client, FakeClient.new([], nil)) { EventStream::Adapters::S3.new(@dest).deliver(@bodies) }
    end
    assert_equal EventStream::Adapters::S3::TOTAL_TIMEOUT, seen
  end
end
