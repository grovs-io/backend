class GoSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::GO
  end
end