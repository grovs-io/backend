class SdkSubdomain
  def self.matches?(request)
    label, = Grovs::Domains.split(request.host)
    label == Grovs::Subdomains::SDK
  end
end
