# Visit http://localhost:3000/rails/mailers/migration_mailer in dev.
class MigrationMailerPreview < ActionMailer::Preview
  def degraded_warning
    MigrationMailer.degraded_warning(sample_snapshot.merge(
      attempts: 47,
      http_code: 401,
      started_at: 2.hours.ago
    ))
  end

  def credentials_invalid
    MigrationMailer.credentials_invalid(sample_snapshot.merge(
      attempts: 500,
      http_code: 401,
      started_at: 2.days.ago
    ))
  end

  private

  def sample_snapshot
    {
      source_id:    42,
      project_id:   1337,
      project_name: "Acme Marketing",
      instance_id:  9001,
      env_type:     "Production",
      provider:     "branch",
      old_host:     "links.acme.com",
      http_code:    401,
      started_at:   2.hours.ago,
      attempts:     47,
      admin_emails: ["alice@acme.com", "bob@acme.com"]
    }
  end
end
