class DnsCnameLookupService
  # Resolv.timeouts retries in sequence; worst case 9s on a Puma thread.
  TIMEOUTS = [3, 6].freeze

  # Public recursive resolvers, queried in order. We pin to known-good nameservers
  # instead of using the system resolver (which on dev machines often includes a
  # local router that "flattens" CNAME chains and returns the final A record
  # instead of preserving the CNAME RR — Resolv::DNS then yields nothing, and
  # preflight reports "no CNAME found" for a hostname whose CNAME is actually live).
  # Cloudflare (1.1.1.1) is first because it's authoritative for our CF-for-SaaS
  # zone; Google (8.8.8.8) is the fallback if CF's resolver is unreachable.
  DEFAULT_NAMESERVERS = %w[1.1.1.1 8.8.8.8].freeze

  class << self
    # Returns [cname_or_nil, dns_error_or_nil]. Never raises — callers render 200 with
    # cname_matches: false and surface the error to the FE.
    def lookup(hostname, nameservers: DEFAULT_NAMESERVERS)
      require "resolv"

      resolver = Resolv::DNS.new(nameserver: nameservers)
      resolver.timeouts = TIMEOUTS

      cname = nil
      resolver.each_resource(hostname, Resolv::DNS::Resource::IN::CNAME) do |r|
        cname ||= r.name.to_s
      end
      [cname, nil]
    rescue Resolv::ResolvError, Resolv::ResolvTimeout, IOError, Errno::ECONNREFUSED, SocketError => e
      [nil, e.class.name]
    ensure
      resolver&.close if resolver.respond_to?(:close)
    end
  end
end
