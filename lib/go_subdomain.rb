class GoSubdomain
  def self.matches?(request)
    label, = Grovs::Domains.split(request.host)
    label == Grovs::Subdomains::GO
  end
end
