class ApiSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::API && Grovs::Domains::MAIN.include?(request.domain)
  end
end