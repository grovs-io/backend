class EventExportJob
  include Sidekiq::Job
  # Retries resume from the checkpoint, so they no longer re-push delivered pages.
  sidekiq_options queue: :egress_exports, retry: 3

  PAGE = 5_000
  QUERY_TIMEOUT = 120
  CHECKPOINT_TTL = 7.days
  RESTING_RETRY = 15.minutes
  # One day per scan, keyset on the rest of the sort key (project_id, toDate(created_at), event_type, event_id).
  EVENTS_PAGE_SQL = <<~SQL.freeze
    SELECT * FROM events FINAL
    WHERE project_id = {project_id:UInt64}
      AND toDate(created_at) = {day:Date}
      AND event_type IN ({types:Array(String)})
      AND (event_type > {after_type:String} OR (event_type = {after_type:String} AND event_id > {after_id:String}))
    ORDER BY event_type, event_id
    LIMIT {limit:UInt32}
  SQL
  PURCHASES_PAGE_SQL = <<~SQL.freeze
    SELECT * FROM purchase_events
    WHERE project_id = {project_id:UInt64}
      AND (transaction_id, event_type) > ({after_txn:String}, {after_type:String})
    ORDER BY transaction_id, event_type, created_at DESC
    LIMIT 1 BY transaction_id, event_type
    LIMIT {limit:UInt32}
  SQL

  def self.checkpoint_key(export_id) = "event_export:checkpoint:#{export_id}"

  def perform(project_id, start_date, end_date, user_id, destination_id = nil, export_id = nil)
    project = Project.find_by(id: project_id)
    user = User.find_by(id: user_id)
    return unless project && user && InstanceRole.exists?(instance_id: project.instance_id, user_id: user.id)

    destination = destination_id && project.event_destinations.find_by(id: destination_id)
    return if destination_id && destination.nil?

    @export_id = export_id || jid || SecureRandom.uuid
    if destination
      # The kill switch, a pause or a backoff holds pushes; retry later rather than drop an accepted export.
      wait = resting_for(destination)
      return self.class.perform_in(wait, project_id, start_date, end_date, user_id, destination_id, @export_id) if wait

      push(project, destination, start_date, end_date)
    else
      deliver_file(project, user, start_date, end_date)
    end
  end

  private

  def resting_for(destination)
    return RESTING_RETRY if !Grovs.event_stream_enabled? || destination.paused?

    destination.backoff_until - Time.current if destination.backoff_until&.future?
  end

  # Runs alongside live delivery on purpose: consumers dedup on id and a backfill carries no ordering promise.
  def push(project, destination, start_date, end_date)
    adapter = destination.s3? ? EventStream::Adapters::S3.new(destination) : EventStream::Adapters::Webhook.new(destination)
    key = self.class.checkpoint_key(@export_id)
    from = JSON.parse(REDIS.with { |c| c.get(key) } || "{}")
    each_page(project, start_date, end_date, destination.event_types, destination.include_ip, from) do |bodies, position|
      accepted, error = adapter.deliver(bodies)
      raise "export delivery failed after #{accepted} events: #{error}" if accepted != bodies.size

      REDIS.with { |c| c.set(key, position.to_json, ex: CHECKPOINT_TTL.to_i) }
    end
    REDIS.with { |c| c.del(key) }
  end

  # Spooled to disk: a wide range can hold more events than the worker has memory.
  def deliver_file(project, user, start_date, end_date)
    spool = Tempfile.new(["events", ".ndjson.gz"], binmode: true)
    Zlib::GzipWriter.wrap(spool) do |writer|
      each_page(project, start_date, end_date, EventDestination::ALL_EVENT_TYPES, false) do |bodies|
        bodies.each { |b| writer.write(b.to_json, "\n") }
      end
    end
    filename = "events_#{project.id}_#{start_date}_#{end_date}.ndjson.gz"
    File.open(spool.path, "rb") do |io|
      download = DownloadableFile.create_file_with_expiration(content: io, filename: filename, content_type: "application/gzip")
      DownloadFileMailer.download_file(download, user).deliver_now
    end
  ensure
    spool&.close!
  end

  # Yields each page with its position; `from` (a saved position) skips everything up to it.
  def each_page(project, start_date, end_date, types, include_ip, from = {})
    builder = EventStream::EnvelopeBuilder.new(project: project, include_ip: include_ip)
    event_types = types - ["purchase"]
    if event_types.any? && from["stage"] != "purchases"
      each_event_page(project, start_date, end_date, event_types, from) { |rows, at| yield builder.build_events(rows), at }
    end
    return unless types.include?("purchase")

    each_purchase_page(project, start_date, end_date, from["stage"] == "purchases" ? from : {}) do |rows, at|
      yield builder.build_purchases(rows), at
    end
  end

  def each_event_page(project, start_date, end_date, types, from)
    first_day = from["day"] ? Date.iso8601(from["day"]) : Date.parse(start_date.to_s)
    (first_day..Date.parse(end_date.to_s)).each do |day|
      after = day.iso8601 == from["day"] ? [from["type"], from["id"]] : ["", ""]
      loop do
        rows = query_rows(EVENTS_PAGE_SQL, project_id: Integer(project.id), day: day.iso8601, types: types,
                                           after_type: after[0], after_id: after[1], limit: page_size)
        break if rows.empty?

        after = [rows.last["event_type"], rows.last["event_id"]]
        yield rows, { "stage" => "events", "day" => day.iso8601, "type" => after[0], "id" => after[1] }
        break if rows.size < page_size
      end
    end
  end

  # Dedup first and filter the date here: a correction dated outside the range must hide its older version.
  def each_purchase_page(project, start_date, end_date, from)
    range = Date.parse(start_date.to_s)..Date.parse(end_date.to_s)
    after = [from["txn"].to_s, from["type"].to_s]
    loop do
      rows = query_rows(PURCHASES_PAGE_SQL, project_id: Integer(project.id), after_txn: after[0], after_type: after[1], limit: page_size)
      break if rows.empty?

      in_range = rows.select { |row| range.cover?(occurred_on(row)) }
      after = [rows.last["transaction_id"], rows.last["event_type"]]
      yield in_range, { "stage" => "purchases", "txn" => after[0], "type" => after[1] } if in_range.any?
      break if rows.size < page_size
    end
  end

  def occurred_on(row)
    recorded = row["recorded_at"]
    occurred = recorded.nil? || recorded.to_i.zero? ? row["purchase_date"] : recorded
    EventStream::Outbox.parse_ts(occurred).to_date
  end

  def page_size = PAGE

  def query_rows(sql, **placeholders)
    query = ClickHouse::Client::Query.new(raw_query: sql, placeholders: placeholders)
    Clickhouse.with_request_timeout(QUERY_TIMEOUT) { Clickhouse.with { |c| c.select_all(query) } }
  end
end
