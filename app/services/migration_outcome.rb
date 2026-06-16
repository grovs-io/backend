# :redirect carries url + link (web uses url, SDK uses link).
# :project_defaults serves the project's default redirect_config.
class MigrationOutcome
  attr_reader :kind, :url, :link, :project, :provider

  def initialize(kind:, url: nil, link: nil, project: nil, provider: nil)
    @kind     = kind
    @url      = url
    @link     = link
    @project  = project
    @provider = provider
  end

  # Appends the original click's query string so UTMs survive the 301 to the new domain.
  def self.redirect(link, query_string: "", provider: nil)
    target = link.access_path
    target = "#{target}?#{query_string}" if query_string.present?
    new(kind: :redirect, url: target, link: link, provider: provider)
  end

  def self.project_defaults(project, provider: nil)
    new(kind: :project_defaults, project: project, provider: provider)
  end

  def redirect?         = kind == :redirect
  def project_defaults? = kind == :project_defaults
end
