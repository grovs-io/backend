class SegmentExportMailer < ApplicationMailer
  layout "branded_mailer"

  def ready(export)
    @export = export
    @email_title = "Segment export ready"
    @segment_url = dashboard_url("/segments/#{export.segment.hashid}", export.project)
    mail(to: export.user.email, subject: "[Grovs] Segment export \"#{export.segment.name}\" is ready")
  end
end
