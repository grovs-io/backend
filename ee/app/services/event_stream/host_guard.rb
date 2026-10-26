module EventStream
  # Refuses tenant URLs that resolve to internal addresses; self-hosted operators may target their own network.
  module HostGuard
    class Blocked < StandardError; end

    mattr_accessor :resolver, default: ->(host) { Resolv.getaddresses(host) }

    module_function

    def blocked?(host)
      vetted_address(host)
      false
    rescue Blocked
      true
    end

    # The one address to connect to; nil when self-hosted, where normal resolution is trusted.
    def vetted_address(host)
      return nil if Grovs.self_hosted?

      addresses = resolver.call(host.to_s)
      raise Blocked, host.to_s if addresses.empty? || addresses.any? { |address| private_address?(address) }

      addresses.first
    rescue Resolv::ResolvError => e
      raise Blocked, e.message
    end

    def private_address?(address)
      ip = IPAddr.new(address)
      ip = ip.native if ip.ipv4_mapped?
      return true if ip.to_i.zero?

      SsoConnections::IssuerValidator::PRIVATE_RANGES.any? { |range| range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end
  end
end
