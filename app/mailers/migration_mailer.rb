class MigrationMailer < ApplicationMailer
  def degraded_warning(snapshot)
    @snapshot = snapshot
    mail(
      bcc: snapshot[:admin_emails],
      subject: "[Grovs] Migration from #{snapshot[:provider].titleize} is failing for #{snapshot[:project_name]}"
    )
  end

  def credentials_invalid(snapshot)
    @snapshot = snapshot
    mail(
      bcc: snapshot[:admin_emails],
      subject: "[Grovs] Migration from #{snapshot[:provider].titleize} disabled — action required"
    )
  end

  # Capture state at enqueue time so the email body reflects what triggered the send,
  # not whatever the source happens to look like minutes later when Sidekiq renders.
  def self.snapshot_for(source)
    project = source.project
    {
      source_id:    source.id,
      project_id:   project.id,
      project_name: project.name,
      instance_id:  project.instance_id,
      # Matches the dashboard's env_type query param ("Production" | "Test") so CTAs
      # land on the right environment's settings page.
      env_type:     project.test? ? "Test" : "Production",
      provider:     source.provider,
      old_host:     source.old_host,
      http_code:    source.last_error_status,
      started_at:   source.first_failure_at,
      attempts:     source.consecutive_failures,
      admin_emails: InstanceRole
                      .where(instance_id: project.instance_id, role: Grovs::Roles::ADMIN)
                      .includes(:user)
                      .map { |ir| ir.user.email }
                      .compact
                      .uniq
    }
  end
end
