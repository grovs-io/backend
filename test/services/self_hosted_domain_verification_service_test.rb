require "test_helper"

class SelfHostedDomainVerificationServiceTest < ActiveSupport::TestCase
  HOST = "links.selfhosted.com".freeze

  def valid_token(hostname = HOST)
    SelfHostedDomainVerificationService.expected_token(hostname)
  end

  def stub_addresses(addresses, &block)
    SelfHostedDomainVerificationService.stub(:resolve_addresses, ->(*) { addresses }, &block)
  end

  def stub_fetch(result, &block)
    fetch = result.is_a?(Exception) ? ->(*) { raise result } : ->(*) { result }
    stub_addresses(["93.184.216.34"]) do
      SelfHostedDomainVerificationService.stub(:fetch, fetch, &block)
    end
  end

  test "activates when the host returns this deployment's token" do
    stub_fetch([200, { token: valid_token }.to_json]) do
      result = SelfHostedDomainVerificationService.verify(HOST)
      assert result.active
      assert_nil result.error
    end
  end

  test "refuses a token from a different deployment" do
    foreign = OpenSSL::HMAC.hexdigest("SHA256", "some-other-deployment-secret", HOST)
    stub_fetch([200, { token: foreign }.to_json]) do
      result = SelfHostedDomainVerificationService.verify(HOST)
      assert_not result.active
      assert_match(/different deployment/i, result.error)
    end
  end

  test "refuses a token minted for a different hostname on this deployment" do
    stub_fetch([200, { token: valid_token("other.example.com") }.to_json]) do
      assert_not SelfHostedDomainVerificationService.verify(HOST).active
    end
  end

  test "refuses an unparseable body" do
    stub_fetch([200, "<html>not json</html>"]) do
      assert_not SelfHostedDomainVerificationService.verify(HOST).active
    end
  end

  test "reports a 404 as the host being served by something else" do
    stub_fetch([404, ""]) do
      result = SelfHostedDomainVerificationService.verify(HOST)
      assert_not result.active
      assert_match(/different deployment/i, result.error)
    end
  end

  test "reports an unexpected status with its code" do
    stub_fetch([502, ""]) do
      assert_match(/502/, SelfHostedDomainVerificationService.verify(HOST).error)
    end
  end

  test "reports a TLS failure without leaking response content" do
    stub_fetch(OpenSSL::SSL::SSLError.new("certificate verify failed")) do
      result = SelfHostedDomainVerificationService.verify(HOST)
      assert_not result.active
      assert_match(/certificate/i, result.error)
      assert_no_match(/verify failed/, result.error)
    end
  end

  test "reports a DNS or connection failure" do
    stub_fetch(SocketError.new("getaddrinfo")) do
      assert_match(/reach/i, SelfHostedDomainVerificationService.verify(HOST).error)
    end
  end

  test "reports a refused connection" do
    stub_fetch(Errno::ECONNREFUSED.new) do
      assert_match(/refused|reset/i, SelfHostedDomainVerificationService.verify(HOST).error)
    end
  end

  test "reports a timeout" do
    stub_fetch(Net::OpenTimeout.new) do
      assert_match(/respond/i, SelfHostedDomainVerificationService.verify(HOST).error)
    end
  end

  test "never raises, whatever the transport does" do
    stub_fetch(StandardError.new("something unexpected")) do
      assert_not SelfHostedDomainVerificationService.verify(HOST).active
    end
  end

  # A hostile A/CNAME record reaching the VPC needs no redirect to do it.
  test "refuses hosts resolving to private, loopback, link-local, CGNAT or ULA addresses" do
    ["127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "169.254.169.254",
     "100.64.0.1", "::1", "fd00::1", "fe80::1"].each do |address|
      called = false
      stub_addresses([address]) do
        SelfHostedDomainVerificationService.stub(:fetch, lambda { |*| 
          called = true
          [200, ""]
        }) do
          result = SelfHostedDomainVerificationService.verify(HOST)
          assert_not result.active, "#{address} must not be probed"
          assert_match(/private address/i, result.error)
        end
      end
      assert_not called, "#{address} must be rejected before any request is made"
    end
  end

  test "refuses 0.0.0.0, which reaches loopback on Linux" do
    stub_addresses(["0.0.0.0"]) do
      assert_not SelfHostedDomainVerificationService.verify(HOST).active
    end
  end

  # Without pinning, the hostname is resolved a second time by Net::HTTP and can rebind.
  test "connects to the screened address rather than re-resolving the hostname" do
    connected_to = :not_called
    stub_addresses(["93.184.216.34"]) do
      Net::HTTP.stub(:start, lambda { |_host, _port, **opts, &_blk|
        connected_to = opts[:ipaddr]
        [200, ""]
      }) do
        SelfHostedDomainVerificationService.verify(HOST)
      end
    end

    assert_equal "93.184.216.34", connected_to
  end

  test "refuses when any one of several resolved addresses is private" do
    stub_addresses(["93.184.216.34", "10.0.0.5"]) do
      assert_not SelfHostedDomainVerificationService.verify(HOST).active
    end
  end

  test "refuses a host that resolves to nothing" do
    stub_addresses([]) do
      assert_not SelfHostedDomainVerificationService.verify(HOST).active
    end
  end

  test "allows an ordinary public address" do
    stub_fetch([200, { token: valid_token }.to_json]) do
      assert SelfHostedDomainVerificationService.verify(HOST).active
    end
  end

  test "stops reading the body at the size cap" do
    chunks_yielded = 0
    response = Object.new
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:read_body) do |&blk|
      loop do
        chunks_yielded += 1
        raise "runaway read: cap not enforced" if chunks_yielded > 64
        blk.call("x" * 1024)
      end
    end

    http = Object.new
    http.define_singleton_method(:request) { |_req, &blk| blk.call(response) }

    stub_addresses(["93.184.216.34"]) do
      Net::HTTP.stub(:start, ->(*, **, &blk) { blk.call(http) }) do
        assert_not SelfHostedDomainVerificationService.verify(HOST).active
      end
    end

    assert_operator chunks_yielded, :<=, 9,
      "an 8 KiB cap should stop after ~8 one-kilobyte chunks, got #{chunks_yielded}"
  end
end
