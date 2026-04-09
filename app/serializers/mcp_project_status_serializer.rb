class McpProjectStatusSerializer
  attr_reader :project

  def initialize(project)
    @project = project
  end

  def self.serialize(record)
    return nil if record.nil?
    new(record).build
  end

  def build
    {
      id: project.hashid,
      name: project.name,
      identifier: project.identifier,
      test: project.test?,
      domain: project.domain&.full_domain,
      has_redirect_config: project.redirect_config&.default_fallback.present?,
      has_links: project.domain&.links&.any? || false
    }
  end
end
