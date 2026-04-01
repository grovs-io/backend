if Doorkeeper::Application.count.zero?
  Doorkeeper::Application.create(name: "React", redirect_uri: "", scopes: "")
end

domain = Domain.find_by(subdomain: Grovs::Subdomains::GO, domain: Grovs::Domains::LIVE)
unless domain
  # We need to create a project
  instance = Instance.new
  instance.uri_scheme = ""
  instance.api_key = ""
  instance.save!

  project = Project.new(name: ENV['PUBLIC_GO_PROJECT_IDENTIFIER'], identifier: ENV['PUBLIC_GO_PROJECT_IDENTIFIER'])
  project.instance = instance
  project.save!

  domain = Domain.new(subdomain: Grovs::Subdomains::GO, domain: Grovs::Domains::LIVE)
  domain.project = project
  domain.save!
end
