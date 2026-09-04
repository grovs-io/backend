module SsoConnections
  module IssuerValidator
    PRIVATE_RANGES = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
                        0.0.0.0/8 ::1/128 fc00::/7 fe80::/10].map { |r| IPAddr.new(r) }.freeze

    module_function

    # Returns nil when the issuer is usable, else a short reason that never echoes the response.
    def error_for(issuer)
      uri = URI.parse(issuer.to_s)
      return "issuer must be an https URL" unless uri.is_a?(URI::HTTPS) && uri.host.present?
      return "issuer resolves to a private address" if !Grovs.self_hosted? && private_host?(uri.host)

      config = OpenIDConnect::Discovery::Provider::Config.discover!(issuer)
      return "discovered endpoint resolves to a private address" if !Grovs.self_hosted? && private_endpoint?(config)

      nil
    rescue URI::InvalidURIError
      "issuer must be an https URL"
    rescue OpenIDConnect::Discovery::DiscoveryFailed, SWD::Exception, Faraday::Error, SocketError => e
      "discovery failed (#{e.class.name.demodulize})"
    end

    def private_endpoint?(config)
      %i[authorization_endpoint token_endpoint userinfo_endpoint jwks_uri].any? do |name|
        url = config.public_send(name)
        url.present? && private_host?(URI.parse(url).host.to_s)
      end
    end

    def private_host?(host)
      addresses = Resolv.getaddresses(host)
      return true if addresses.empty?

      addresses.any? do |a|
        ip = IPAddr.new(a)
        ip = ip.native if ip.ipv4_mapped?
        PRIVATE_RANGES.any? { |r| r.include?(ip) }
      end
    rescue IPAddr::InvalidAddressError, Resolv::ResolvError
      true
    end
  end
end
