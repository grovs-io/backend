if ENV["OAUTH_CLIENT_UID"].present? && ENV["OAUTH_CLIENT_SECRET"].present?
  # Self-hosted: deterministic OAuth credentials (idempotent upsert).
  app = Doorkeeper::Application.find_or_initialize_by(name: "React")
  app.update!(uid: ENV["OAUTH_CLIENT_UID"], secret: ENV["OAUTH_CLIENT_SECRET"], redirect_uri: "", scopes: "")
elsif Doorkeeper::Application.count.zero?
  Doorkeeper::Application.create(name: "React", redirect_uri: "", scopes: "") # legacy: random creds
end

# The go.<domain> quick-link subdomain is Grovs SaaS plumbing. Self-hosted
# installs have no use for it, and the enterprise image has no dotfiles, so
# PUBLIC_GO_PROJECT_IDENTIFIER is genuinely nil there — seeding it would fail
# validation and abort the one-shot migrate task.
unless Grovs.self_hosted?
  domain = Domain.find_by(subdomain: Grovs::Subdomains::GO, domain: Grovs::Domains::LIVE)
  unless domain
    go_identifier = ENV.fetch('PUBLIC_GO_PROJECT_IDENTIFIER', 'public-go-links')

    # Transactional: the instance is saved with validate: false, so a later failure
    # would otherwise leave an orphan Instance behind and leak another on every retry.
    ActiveRecord::Base.transaction do
      # go instance intentionally has blank scheme/key; skip validation (matches prod).
      instance = Instance.new
      instance.uri_scheme = ""
      instance.api_key = ""
      instance.save!(validate: false)

      project = Project.new(name: go_identifier, identifier: go_identifier)
      project.instance = instance
      project.save!

      domain = Domain.new(subdomain: Grovs::Subdomains::GO, domain: Grovs::Domains::LIVE)
      domain.project = project
      domain.save!
    end
  end
end

if ENV["BOOTSTRAP_ADMIN_EMAIL"].present? && ENV["BOOTSTRAP_ADMIN_PASSWORD"].present?
  # Downcased to match Devise, so re-seeding with different casing is idempotent.
  admin_email = ENV["BOOTSTRAP_ADMIN_EMAIL"].to_s.strip.downcase
  admin = User.find_or_initialize_by(email: admin_email)
  if admin.new_record?
    admin.name = "Admin"
    admin.password = ENV["BOOTSTRAP_ADMIN_PASSWORD"]
    admin.save!
  end
  # No instance is created; the admin makes one through onboarding.
end
