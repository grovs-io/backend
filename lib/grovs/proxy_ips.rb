# frozen_string_literal: true

module Grovs
  # Proxies scrubbed from X-Forwarded-For before the app resolves request.ip.
  module ProxyIps
    CLOUDFLARE = %w[
      173.245.48.0/20
      103.21.244.0/22
      103.22.200.0/22
      103.31.4.0/22
      141.101.64.0/18
      108.162.192.0/18
      190.93.240.0/20
      188.114.96.0/20
      197.234.240.0/22
      198.41.128.0/17
      162.158.0.0/15
      104.16.0.0/13
      104.24.0.0/14
      172.64.0.0/13
      131.0.72.0/22
    ].freeze

    # A customer's gateway fronting the origin (CUSTOMER_GATEWAY_IPS) must be scrubbed like Cloudflare,
    # or request.ip resolves to the gateway and the fingerprint key never matches the app side.
    def self.scrubbed(env = ENV)
      CLOUDFLARE + env.fetch("CUSTOMER_GATEWAY_IPS", "").split(/[,\s]+/).reject(&:empty?)
    end
  end
end
