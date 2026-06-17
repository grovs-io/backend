require "test_helper"

# Seed creates a deterministic OAuth app + bootstrap admin only when the env vars
# are set, idempotently; unset = legacy seed behavior. Transactional tests roll back.
class SelfHostedSeedBootstrapTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains

  setup do
    @keys = %w[OAUTH_CLIENT_UID OAUTH_CLIENT_SECRET BOOTSTRAP_ADMIN_EMAIL BOOTSTRAP_ADMIN_PASSWORD]
    @saved = @keys.index_with { |k| ENV[k] }
    ENV["OAUTH_CLIENT_UID"] = "sh-uid-#{SecureRandom.hex(6)}"
    ENV["OAUTH_CLIENT_SECRET"] = "sh-secret-#{SecureRandom.hex(6)}"
    ENV["BOOTSTRAP_ADMIN_EMAIL"] = "bootstrap-admin@example.com"
    ENV["BOOTSTRAP_ADMIN_PASSWORD"] = "bootstrap-pass-123"

    # Pre-create the go domain so load_seed skips its unrelated (not test-safe) go block.
    ensure_go_domain
  end

  teardown do
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "deterministic OAuth app + bootstrap admin are created, with ADMIN role, idempotently" do
    Rails.application.load_seed

    app = Doorkeeper::Application.find_by(name: "React")
    assert_equal ENV["OAUTH_CLIENT_UID"], app.uid, "React app uid must match OAUTH_CLIENT_UID"
    assert_equal ENV["OAUTH_CLIENT_SECRET"], app.secret

    admin = User.find_by(email: "bootstrap-admin@example.com")
    assert_not_nil admin, "bootstrap admin must be created"
    assert admin.valid_password?("bootstrap-pass-123")
    assert_equal 1, admin.instances.count, "admin must own exactly one instance"
    role = InstanceRole.find_by(user_id: admin.id, instance_id: admin.instances.first.id)
    assert_equal Grovs::Roles::ADMIN, role.role, "bootstrap admin must be ROLE_ADMIN of its instance"

    # Idempotency: re-running must not duplicate the instance or rotate the password.
    Rails.application.load_seed
    admin.reload
    assert_equal 1, admin.instances.count, "re-seeding must not duplicate the admin's instance"
    assert admin.valid_password?("bootstrap-pass-123"), "re-seeding must not rotate the password"
  end

  test "with bootstrap env unset, no admin is created (SaaS unchanged)" do
    ENV.delete("OAUTH_CLIENT_UID")
    ENV.delete("OAUTH_CLIENT_SECRET")
    ENV.delete("BOOTSTRAP_ADMIN_EMAIL")
    ENV.delete("BOOTSTRAP_ADMIN_PASSWORD")

    Rails.application.load_seed
    assert_nil User.find_by(email: "bootstrap-admin@example.com")
  end

  private

  def ensure_go_domain
    return if Domain.find_by(subdomain: Grovs::Subdomains::GO, domain: Grovs::Domains::LIVE)

    instance = Instance.create!(uri_scheme: "goseed", api_key: "goseed#{SecureRandom.hex(4)}")
    project  = Project.create!(name: "go-seed", identifier: "go-seed-#{SecureRandom.hex(4)}", instance: instance, test: false)
    Domain.create!(project: project, subdomain: Grovs::Subdomains::GO, domain: Grovs::Domains::LIVE)
  end
end
