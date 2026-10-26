class EventStreamMailer < ApplicationMailer
  layout "branded_mailer"

  def paused(destination)
    @destination = destination
    @email_title = "Event stream paused"
    @settings_url = settings_url(destination)
    mail(bcc: admin_emails(destination), subject: "[Grovs] Event stream destination \"#{destination.name}\" paused")
  end

  def gap(destination, from:, to:)
    @destination = destination
    @from = from
    @to = to
    @email_title = "Event stream gap"
    @settings_url = settings_url(destination)
    mail(bcc: admin_emails(destination), subject: "[Grovs] Event stream destination \"#{destination.name}\" skipped a gap")
  end

  private

  def settings_url(destination) = dashboard_url("/settings/developers/event_stream", destination.project)

  def admin_emails(destination)
    InstanceRole.where(instance_id: destination.project.instance_id, role: Grovs::Roles::ADMIN).includes(:user).map { |ir| ir.user.email }.compact.uniq
  end
end
