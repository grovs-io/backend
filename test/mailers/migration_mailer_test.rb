require "test_helper"

class MigrationMailerTest < ActionMailer::TestCase
  SNAPSHOT = {
    source_id: 42, project_id: 1337, project_name: "Acme", instance_id: 9001, env_type: "Test",
    provider: "branch", old_host: "links.acme.com", http_code: 401, started_at: Time.utc(2026, 1, 1),
    attempts: 47, admin_emails: ["alice@acme.com"]
  }.freeze

  MIGRATION_LINK = "https://app.grovs.io/dynamic_links/settings/domain?instance_id=9001&env_type=Test#migration".freeze

  test "degraded_warning links to the migration card" do
    assert_includes MigrationMailer.degraded_warning(SNAPSHOT).body.encoded, MIGRATION_LINK
  end

  test "credentials_invalid links to the migration card" do
    assert_includes MigrationMailer.credentials_invalid(SNAPSHOT).body.encoded, MIGRATION_LINK
  end
end
