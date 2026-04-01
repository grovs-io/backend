class DomainConfigurationService
  # Updates domain with attrs + optional image. Returns Domain.
  def self.update_domain(domain:, attrs:, generic_image: nil)
    if attrs[:subdomain] && attrs[:subdomain].downcase != domain.subdomain&.downcase
      available = subdomain_available?(subdomain: attrs[:subdomain], is_test: domain.project.test?)
      raise ArgumentError, "Subdomain not available" unless available
    end

    domain.update(attrs)
    domain.subdomain = domain.subdomain&.downcase
    domain.save!

    if generic_image
      domain.generic_image_url = nil
      domain.generic_image.attach(generic_image)
      domain.save!
    end

    if attrs[:generic_image_url]
      domain.generic_image_url = attrs[:generic_image_url]
      domain.generic_image.purge
      domain.save!
    end

    domain
  end

  # Returns Boolean — checks forbidden list, format, uniqueness.
  def self.subdomain_available?(subdomain:, is_test:)
    return false if Grovs::Subdomains::FORBIDDEN.include?(subdomain)
    return false unless alphanumeric_without_spaces?(subdomain)

    domain = Domain.joins(:project).find_by(subdomain: subdomain, projects: { test: is_test })
    domain.nil?
  end

  # Returns Boolean.
  def self.domain_available?(domain_name:)
    Domain.find_by(domain: domain_name).nil?
  end

  private

  def self.alphanumeric_without_spaces?(string)
    return false if string.match?(/\A[-_]+\z/)
    !string.match(/\A[a-zA-Z0-9\-_]*\z/).nil?
  end
end
