
class PreviewSubdomain
  def self.matches?(request)
    request.subdomain == Grovs::Subdomains::PREVIEW
  end
end