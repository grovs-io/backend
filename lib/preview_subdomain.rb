
class PreviewSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::PREVIEW && Grovs::Domains::MAIN.include?(request.domain)
  end
end