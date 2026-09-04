class PublicSubdomain
  def self.matches?(request)
    label, = Grovs::Domains.split(request.host)
    # Custom/enterprise host (no MAIN suffix): public link host when Rails
    # extracts a registrable domain (IPv4 literals don't get one).
    return request.domain.present? if label.nil?
    # On our own domains a bare apex and the reserved labels have their own handlers.
    return false if label.blank?

    !Grovs::Subdomains::FORBIDDEN.include?(label)
  end
end
