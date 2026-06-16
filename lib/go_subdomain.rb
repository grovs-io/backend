class GoSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::GO && Grovs::Domains::MAIN.include?(request.domain)
  end
end