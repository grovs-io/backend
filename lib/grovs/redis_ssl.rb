require 'openssl'

module Grovs
  # Single source of Redis TLS options; only takes effect on rediss:// URLs.
  module RedisSsl
    def self.params
      return { verify_mode: OpenSSL::SSL::VERIFY_NONE } if verification_disabled?

      params = { verify_mode: OpenSSL::SSL::VERIFY_PEER }
      ca_file = ENV['REDIS_SSL_CA_FILE'].to_s.strip
      return params if ca_file.empty?

      unless File.readable?(ca_file)
        raise ArgumentError,
              "REDIS_SSL_CA_FILE is set to #{ca_file.inspect}, which is not readable in this container. " \
              "Mount the bundle at that path, fix the value, or unset it to use the system trust store."
      end

      params[:ca_file] = ca_file
      params
    end

    def self.verification_disabled?
      ENV['REDIS_SSL_VERIFY'].to_s.strip.downcase == 'none'
    end
  end
end
