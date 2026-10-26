class PurgeSegmentExportJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 3

  def perform(export_id)
    export = SegmentExport.find_by(id: export_id)
    return if export.nil?

    export.file.purge if export.file.attached?
    export.update_columns(status: "expired", updated_at: Time.current)
  end
end
