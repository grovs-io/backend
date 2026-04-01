class ApiSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::API
    # return true
  end
end