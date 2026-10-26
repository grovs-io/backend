module EventStream
  # The only ClickHouse access for the Stream; every query is project-bound (tenant separation).
  module Outbox
    RETENTION_DAYS = 7
    TS_FMT = Analytics::QueryHelpers::CH_DATETIME_FMT
    EPOCH = "1970-01-01 00:00:00.000".freeze

    module_function

    def format_ts(time)
      time.utc.strftime(TS_FMT)
    end

    def parse_ts(value)
      return value.utc if value.is_a?(Time)

      Time.find_zone("UTC").parse(value.to_s).utc
    end

    # Capture runs while a project has any consumer; the project lock serializes concurrent creates and deletes.
    def sync_project!(project)
      project.with_lock do
        if project.event_destinations.exists? || project.event_stream_tokens.active.exists?
          enable_project!(project.id)
        else
          disable_project!(project.id)
          purge_project!(project.id)
        end
      end
    end

    def enable_project!(project_id)
      Clickhouse.with { |c| c.insert("egress_projects", [{ project_id: Integer(project_id) }]) }
    end

    def disable_project!(project_id)
      execute("ALTER TABLE egress_projects DELETE WHERE project_id = {project_id:UInt64}", project_id: Integer(project_id))
    end

    def purge_project!(project_id)
      execute("ALTER TABLE events_outbox DELETE WHERE project_id = {project_id:UInt64}", project_id: Integer(project_id))
      execute("ALTER TABLE purchase_events_outbox DELETE WHERE project_id = {project_id:UInt64}", project_id: Integer(project_id))
    end

    def enabled_project_ids
      Clickhouse.with { |c| c.select_all("SELECT DISTINCT project_id FROM egress_projects") }.map { |r| Integer(r["project_id"]) }
    end

    # From the clock that stamps outbox_at, so app clock skew cannot move the cutoff past unread rows.
    def cutoff(lag_seconds)
      sql = "SELECT toString(now64(3, 'UTC') - toIntervalSecond({lag:UInt32}))"
      parse_ts(Clickhouse.with { |c| c.select_value(ClickHouse::Client::Query.new(raw_query: sql, placeholders: { lag: Integer(lag_seconds) })) })
    end

    def read_events(project_id:, after_at:, after_id:, event_types:, limit:, cutoff:)
      types_sql = event_types.present? ? "AND event_type IN ({types:Array(String)})" : ""
      query = ClickHouse::Client::Query.new(
        raw_query: <<~SQL,
          SELECT * FROM events_outbox
          WHERE project_id = {project_id:UInt64}
            AND (outbox_at, event_id) > ({after_at:DateTime64(3, 'UTC')}, {after_id:String})
            AND outbox_at < {cutoff:DateTime64(3, 'UTC')}
            #{types_sql}
          ORDER BY outbox_at, event_id
          LIMIT {limit:UInt32}
        SQL
        placeholders: { project_id: Integer(project_id), after_at: after_at ? format_ts(after_at) : EPOCH, after_id: after_id.to_s,
                        cutoff: format_ts(cutoff), limit: Integer(limit), types: Array(event_types).map(&:to_s) }
      )
      Clickhouse.with { |c| c.select_all(query) }
    end

    def read_purchases(project_id:, after_at:, after_id:, limit:, cutoff:)
      query = ClickHouse::Client::Query.new(
        raw_query: <<~SQL,
          SELECT * FROM purchase_events_outbox
          WHERE project_id = {project_id:UInt64}
            AND (outbox_at, purchase_key) > ({after_at:DateTime64(3, 'UTC')}, {after_id:String})
            AND outbox_at < {cutoff:DateTime64(3, 'UTC')}
          ORDER BY outbox_at, purchase_key
          LIMIT {limit:UInt32}
        SQL
        placeholders: { project_id: Integer(project_id), after_at: after_at ? format_ts(after_at) : EPOCH, after_id: after_id.to_s,
                        cutoff: format_ts(cutoff), limit: Integer(limit) }
      )
      Clickhouse.with { |c| c.select_all(query) }
    end

    # Merged by arrival. Each page holds at most `limit` sorted rows, so anything past a full page's
    # last row sits behind `limit` earlier rows and `first(limit)` already drops it; ties keep events first.
    def merge_by_arrival(events, purchases, limit)
      tagged = events.map { |row| [:event, row] } + purchases.map { |row| [:purchase, row] }
      tagged.each_with_index.sort_by { |(_kind, row), i| [row["outbox_at"], i] }.map(&:first).first(limit)
    end

    def execute(sql, **placeholders)
      Clickhouse.with { |c| c.execute(ClickHouse::Client::Query.new(raw_query: sql, placeholders: placeholders)) }
    end
    private_class_method :execute
  end
end
