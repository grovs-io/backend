class SdkSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::SDK
    # return true
  end
end