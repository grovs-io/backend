class GooglePubsubVerifier
  # Returns decoded payload hash or nil.
  def self.verify(token)
    return nil unless token.present?

    certs = fetch_certs
    return nil unless certs

    header = JSON.parse(Base64.urlsafe_decode64(token.split(".").first))
    kid = header["kid"]
    cert_data = certs[kid]
    return nil unless cert_data

    key = OpenSSL::X509::Certificate.new(cert_data).public_key
    decoded = JWT.decode(token, key, true, {
      algorithm: "RS256",
      iss: "https://accounts.google.com",
      verify_iss: true
    })
    decoded.first
  rescue JWT::DecodeError, JSON::ParserError,
         OpenSSL::X509::CertificateError, ArgumentError => e
    Rails.logger.warn "Google Pub/Sub JWT decode failed: #{e.class} - #{e.message}"
    nil
  end

  private

  def self.fetch_certs
    cached = Rails.cache.read("google_pubsub_certs")
    return cached if cached

    uri = URI("https://www.googleapis.com/oauth2/v1/certs")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
      http.get(uri.path)
    end
    certs = JSON.parse(response.body)
    Rails.cache.write("google_pubsub_certs", certs, expires_in: 1.hour)
    certs
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError,
         Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError,
         JSON::ParserError => e
    Rails.logger.error "Failed to fetch Google certs: #{e.class} - #{e.message}"
    nil
  end
end
