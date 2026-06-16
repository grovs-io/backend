class PublicSubdomain
  def self.matches?(request)
    return false if request.domain.blank?

    # Custom / enterprise host: the registrable domain isn't one of ours, so it's
    # always a public link host regardless of the subdomain label (sdk., api., ...).
    return true unless Grovs::Domains::MAIN.include?(request.domain)

    # Our own domain: a bare apex is not a public link host, and reserved
    # subdomains (sdk/api/go/preview/mcp/proxy) belong to their own handlers.
    subdomain = request.subdomain
    return false if subdomain.blank?

    !Grovs::Subdomains::FORBIDDEN.include?(subdomain)
  end
end