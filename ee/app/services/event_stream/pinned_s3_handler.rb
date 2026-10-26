module EventStream
  class PinnedS3Handler < Seahorse::Client::NetHttp::Handler
    private

    # Validate the final bucket hostname and pin its IP while preserving TLS hostname verification.
    def session(config, request)
      endpoint = request.endpoint
      raise ArgumentError, "S3 endpoint must use HTTPS" unless endpoint.is_a?(URI::HTTPS)

      address = HostGuard.vetted_address(endpoint.host)
      http = Net::HTTP.new(endpoint.host, endpoint.port, nil)
      http.ipaddr = address
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.ca_file = config.ssl_ca_bundle if config.ssl_ca_bundle
      http.ca_path = config.ssl_ca_directory if config.ssl_ca_directory
      http.cert_store = config.ssl_ca_store if config.ssl_ca_store
      http.open_timeout = config.http_open_timeout
      http.read_timeout = config.http_read_timeout
      http.write_timeout = config.http_read_timeout
      http.max_retries = 0
      http.start { yield http }
    end
  end
end
