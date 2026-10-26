module EventStream
  # Connects to the address HostGuard vetted so a second DNS answer cannot redirect it; TLS still verifies the hostname.
  class PinnedConnection < HTTParty::ConnectionAdapter
    def connection
      http = super
      address = options.dig(:connection_adapter_options, :ipaddr)
      http.ipaddr = address if address
      http
    end
  end
end
