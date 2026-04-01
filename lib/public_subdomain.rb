class PublicSubdomain
  def self.matches?(request)
    subdomain = request.subdomain
    if subdomain.blank?
      return request.domain.present? && !Grovs::Domains::MAIN.include?(request.domain)
    end

    subdomain.present? && !Grovs::Subdomains::FORBIDDEN.include?(subdomain)
  end
end