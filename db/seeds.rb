if ENV["OAUTH_CLIENT_UID"].present? && ENV["OAUTH_CLIENT_SECRET"].present?
  # Self-hosted: deterministic OAuth credentials (idempotent upsert).
  app = Doorkeeper::Application.find_or_initialize_by(name: "React")
  app.update!(uid: ENV["OAUTH_CLIENT_UID"], secret: ENV["OAUTH_CLIENT_SECRET"], redirect_uri: "", scopes: "")
elsif Doorkeeper::Application.count.zero?
  Doorkeeper::Application.create(name: "React", redirect_uri: "", scopes: "") # legacy: random creds
end

domain = Domain.find_by(subdomain: Grovs::Subdomains::GO, domain: Grovs::Domains::LIVE)
unless domain
  # go instance intentionally has blank scheme/key; skip validation (matches prod).
  instance = Instance.new
  instance.uri_scheme = ""
  instance.api_key = ""
  instance.save!(validate: false)

  project = Project.new(name: ENV['PUBLIC_GO_PROJECT_IDENTIFIER'], identifier: ENV['PUBLIC_GO_PROJECT_IDENTIFIER'])
  project.instance = instance
  project.save!

  domain = Domain.new(subdomain: Grovs::Subdomains::GO, domain: Grovs::Domains::LIVE)
  domain.project = project
  domain.save!
end

if ENV["BOOTSTRAP_ADMIN_EMAIL"].present? && ENV["BOOTSTRAP_ADMIN_PASSWORD"].present?
  # Self-hosted: first admin from env (no SMTP/SSO needed). Idempotent — never
  # rotates an existing user's password or duplicates their instance.
  admin = User.find_or_initialize_by(email: ENV["BOOTSTRAP_ADMIN_EMAIL"])
  if admin.new_record?
    admin.name = "Admin"
    admin.password = ENV["BOOTSTRAP_ADMIN_PASSWORD"]
    admin.save!
  end

  if admin.persisted? && admin.instances.empty?
    InstanceProvisioningService.new(current_user: admin).create(name: "Default")
  end
end
