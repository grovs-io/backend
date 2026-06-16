require "test_helper"
require "resolv"

class DnsCnameLookupServiceTest < ActiveSupport::TestCase
  FakeCname = Struct.new(:name) do
    def to_s = name
  end

  test "returns the first CNAME and nil error on a successful lookup" do
    fake_resolver = Object.new
    def fake_resolver.timeouts=(_); end
    def fake_resolver.each_resource(_host, _type)
      yield FakeCname.new("proxy.sqd.link")
    end
    def fake_resolver.close; end

    Resolv::DNS.stub(:new, fake_resolver) do
      cname, err = DnsCnameLookupService.lookup("branch.acme.com")
      assert_equal "proxy.sqd.link", cname
      assert_nil err
    end
  end

  test "returns [nil, error_class_name] on a DNS timeout" do
    fake_resolver = Object.new
    def fake_resolver.timeouts=(_); end
    def fake_resolver.each_resource(_host, _type)
      raise Resolv::ResolvTimeout, "boom"
    end
    def fake_resolver.close; end

    Resolv::DNS.stub(:new, fake_resolver) do
      cname, err = DnsCnameLookupService.lookup("branch.acme.com")
      assert_nil cname
      assert_equal "Resolv::ResolvTimeout", err
    end
  end

  test "returns [nil, nil] for an A-only hostname (no CNAME exists)" do
    fake_resolver = Object.new
    def fake_resolver.timeouts=(_); end
    def fake_resolver.each_resource(_host, _type)
    end
    def fake_resolver.close; end

    Resolv::DNS.stub(:new, fake_resolver) do
      cname, err = DnsCnameLookupService.lookup("apex-only.example.com")
      assert_nil cname, "A-only host has no CNAME to return"
      assert_nil err, "missing CNAME is NOT a DNS error — surfacing one would mislead the FE"
    end
  end

  # Production / staging may have a system /etc/resolv.conf pointed at a local router
  # or a recursive resolver that "flattens" CNAME chains — returning the final A
  # record and dropping the CNAME RR. Resolv::DNS then yields zero CNAME records and
  # preflight wrongly reports "no CNAME found" for a hostname whose CNAME is live.
  # Pinning to public recursive resolvers (1.1.1.1, 8.8.8.8) eliminates that flake.
  test "uses pinned public nameservers, not the host's /etc/resolv.conf" do
    captured_nameserver = nil
    fake_factory = lambda do |**kwargs|
      captured_nameserver = kwargs[:nameserver]
      r = Object.new
      def r.timeouts=(_); end
      def r.each_resource(_host, _type) = yield Struct.new(:name).new("proxy.sqd.link")
      def r.close; end
      r
    end
    Resolv::DNS.stub(:new, fake_factory) do
      DnsCnameLookupService.lookup("branch.acme.com")
    end
    assert_equal %w[1.1.1.1 8.8.8.8], captured_nameserver,
                 "must pass nameserver: [...] to Resolv::DNS.new so the system resolver is bypassed"
  end

  test "caller can override the nameserver list (escape hatch for staging-only resolvers)" do
    captured_nameserver = nil
    fake_factory = lambda do |**kwargs|
      captured_nameserver = kwargs[:nameserver]
      r = Object.new
      def r.timeouts=(_); end
      def r.each_resource(_host, _type); end
      def r.close; end
      r
    end
    Resolv::DNS.stub(:new, fake_factory) do
      DnsCnameLookupService.lookup("branch.acme.com", nameservers: ["9.9.9.9"])
    end
    assert_equal ["9.9.9.9"], captured_nameserver
  end
end
