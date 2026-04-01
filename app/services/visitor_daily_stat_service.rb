class VisitorDailyStatService
  def self.increment_visitor_event(visitor:, event_type:, platform:, event_date: Date.current, project_id: nil, link_id: nil, value: 1)
    raise ArgumentError, "Invalid event type: #{event_type}" unless VisitorDailyStatistic::METRIC_COLUMNS.include?(event_type)

    ActiveRecord::Base.with_connection do |conn|
      now = conn.quote(Time.current)

      quoted_value = conn.quote(value.to_i)

      metric_values = VisitorDailyStatistic::METRIC_COLUMNS.map do |col|
        col == event_type ? quoted_value : conn.quote(0)
      end

      sql = <<~SQL
        INSERT INTO visitor_daily_statistics
          (project_id, visitor_id, event_date, platform, invited_by_id,
           #{VisitorDailyStatistic::METRIC_COLUMNS.join(', ')},
           created_at, updated_at)
        VALUES
          (#{conn.quote(project_id)}, #{conn.quote(visitor.id)}, #{conn.quote(event_date)},
           #{conn.quote(platform)}, #{conn.quote(visitor.inviter_id)},
           #{metric_values.join(', ')},
           #{now}, #{now})
        ON CONFLICT (project_id, visitor_id, event_date, platform)
        DO UPDATE SET
          #{event_type} = COALESCE(visitor_daily_statistics.#{event_type}, 0) + #{quoted_value},
          invited_by_id = COALESCE(visitor_daily_statistics.invited_by_id, EXCLUDED.invited_by_id),
          updated_at = #{now}
      SQL

      conn.execute(sql)
    end
  end

  COLUMNS = %i[
    project_id visitor_id event_date invited_by_id
    views opens installs reinstalls time_spent revenue reactivations app_opens user_referred
    created_at updated_at platform
  ].freeze

  CONFLICT_KEYS = %i[project_id visitor_id event_date platform].freeze

  def self.bulk_upsert_visitor_stats(visitor_stats)
    return if visitor_stats.blank?

    # Group by ON CONFLICT key: (project_id, visitor_id, event_date, platform).
    # invited_by_id is NOT part of the conflict key, so it must not be in
    # the grouping key — otherwise two stats with the same conflict key but
    # different invited_by_ids produce two INSERT rows that collide on the
    # same unique index → "cannot affect row a second time" error.
    grouped = Hash.new { |h, k| h[k] = { metrics: Hash.new(0), invited_by_id: nil } }
    visitor_stats.each do |stat|
      key = [stat[:project_id], stat[:visitor_id], stat[:event_date], stat[:platform]]
      entry = grouped[key]
      metrics = stat[:metrics] || {}

      Grovs::Events::MAPPING.each_value do |metric|
        entry[:metrics][metric] += metrics[metric] || 0
      end

      # Keep first non-nil invited_by_id
      entry[:invited_by_id] ||= stat[:invited_by_id]
    end

    rows = grouped.map do |(project_id, visitor_id, event_date, platform), entry|
      metrics = entry[:metrics]
      {
        project_id: project_id,
        visitor_id: visitor_id,
        event_date: event_date,
        invited_by_id: entry[:invited_by_id],
        views: metrics[:views] || 0,
        opens: metrics[:opens] || 0,
        installs: metrics[:installs] || 0,
        reinstalls: metrics[:reinstalls] || 0,
        time_spent: metrics[:time_spent] || 0,
        revenue: metrics[:revenue] || 0,
        reactivations: metrics[:reactivations] || 0,
        app_opens: metrics[:app_opens] || 0,
        user_referred: metrics[:user_referred] || 0,
        created_at: Time.current,
        updated_at: Time.current,
        platform: platform
      }
    end

    if rows.any?
      # Sort by conflict key to prevent deadlocks between concurrent workers
      rows.sort_by! { |r| [r[:project_id], r[:visitor_id], r[:event_date].to_s, r[:platform].to_s] }
      bulk_increment_visitor_stats(rows)
    end
  end

  private

  def self.bulk_increment_visitor_stats(rows)
    BulkUpsertHelper.execute(
      table: "visitor_daily_statistics",
      rows: rows,
      columns: COLUMNS,
      conflict_keys: CONFLICT_KEYS,
      metric_columns: VisitorDailyStatistic::METRIC_COLUMNS,
      extra_conflict_sets: ["invited_by_id = COALESCE(visitor_daily_statistics.invited_by_id, EXCLUDED.invited_by_id)"]
    )
  end
end
