require "csv"

class SegmentExportJob
  include Sidekiq::Job
  sidekiq_options queue: :egress_exports, retry: 0

  PAGE = 10_000
  HEADERS = %w[person_key visitor_uuid sdk_identifier sdk_attributes created_at].freeze
  KEEP_FOR = 24.hours
  FORMULA_PREFIX = /\A[=+\-@\t\r]/
  MAX_BUSY_RETRIES = 3

  def perform(export_id, attempt = 0)
    export = SegmentExport.find_by(id: export_id)
    return if export.nil? || export.status != "pending"

    build(export)
  rescue Segments::Busy => e
    return self.class.perform_in(rand(2..10).minutes, export_id, attempt + 1) if attempt < MAX_BUSY_RETRIES

    fail_export(export, e)
    raise
  rescue StandardError => e
    fail_export(export, e)
    raise
  end

  private

  def fail_export(export, error)
    return unless export&.status == "pending"

    export.file.purge if export.file.attached?
    export.update_columns(status: "failed", error: error.class.name, updated_at: Time.current)
  end

  # The request-time snapshot is evaluated, so a later segment edit cannot change the file.
  def build(export)
    definition = Segments::Definition.parse(export.definition, cutoff_date: nil)
    manifest = Segments::Results.for(project: export.project, definition: definition, list_generation: export.identifier_list_generation,
                                      segment_id: export.segment_id)
    rows = 0
    Tempfile.create(["segment", ".csv"]) do |spool|
      csv = CSV.new(spool)
      csv << HEADERS
      each_user(manifest) do |u|
        csv << csv_row(u)
        rows += 1
      end
      Segments::Results.fetch!(export.project_id, manifest.result_id)
      spool.rewind
      export.file.attach(io: spool, filename: "segment_#{export.segment.hashid}_#{Date.current}.csv", content_type: "text/csv")
    end
    # An existing file must be on its 24h clock before the export looks "ready".
    PurgeSegmentExportJob.perform_in(KEEP_FOR, export.id)
    export.update!(status: "ready", rows: rows)
    deliver_ready_mail(export)
  end

  def deliver_ready_mail(export)
    return unless export.user

    SegmentExportMailer.ready(export).deliver_now
  rescue StandardError => e
    Rails.logger.warn("segments.export.mail_failed export=#{export.id} #{e.class}")
  end

  def each_user(manifest, &)
    after = 0
    loop do
      page = Segments::Members.page(manifest: manifest, after: after, limit: PAGE, max: PAGE)
      page[:users].each(&)
      after = page[:next_after]
      break if after.nil?
    end
  end

  def csv_row(user)
    [csv_safe(user["person_key"]), user["uuid"], csv_safe(user["sdk_identifier"]),
     csv_safe(user["sdk_attributes"]&.to_json), user["created_at"]]
  end

  def csv_safe(value)
    value.to_s.match?(FORMULA_PREFIX) ? "'#{value}" : value
  end
end
