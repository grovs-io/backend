class ApiSubdomain
  def self.matches?(request)
    label, = Grovs::Domains.split(request.host)
    label == Grovs::Subdomains::API
  end
end
