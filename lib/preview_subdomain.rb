class PreviewSubdomain
  def self.matches?(request)
    label, = Grovs::Domains.split(request.host)
    label == Grovs::Subdomains::PREVIEW
  end
end
