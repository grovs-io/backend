class SdkSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::SDK && Grovs::Domains::MAIN.include?(request.domain)
  end
end