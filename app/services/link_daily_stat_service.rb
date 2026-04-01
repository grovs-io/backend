class LinkDailyStatService
  def self.increment_link_event(event_type:, project_id:, link_id:, platform:, event_date: Date.current, value: 1)
    raise ArgumentError, "Invalid event type: #{event_type}" unless LinkDailyStatistic::METRIC_COLUMNS.include?(event_type)

    conditions = {
      project_id: project_id,
      link_id: link_id,
      platform: platform,
      event_date: event_date
    }

    begin
      quoted_value = ActiveRecord::Base.connection.quote(value.to_i)
      updated_rows = LinkDailyStatistic.where(conditions).update_all(
        "#{event_type} = COALESCE(#{event_type}, 0) + #{quoted_value}, updated_at = NOW()"
      )

      if updated_rows == 0
        attrs = conditions.merge(
          event_type => value
        )

        # ensure all metrics are present
        LinkDailyStatistic::METRIC_COLUMNS.each do |col|
          attrs[col] ||= 0
        end

        LinkDailyStatistic.create!(attrs)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end

  COLUMNS = %i[
    project_id link_id event_date
    views opens installs reinstalls time_spent revenue reactivations app_opens user_referred
    created_at updated_at platform
  ].freeze

  CONFLICT_KEYS = %i[project_id link_id event_date platform].freeze

  def self.bulk_upsert_link_stats(link_stats)
    return if link_stats.blank?

    # Group by project_id + link_id + event_date and sum the metrics
    grouped = Hash.new { |h, k| h[k] = Hash.new(0) }
    link_stats.each do |stat|
      key = [stat[:project_id], stat[:link_id], stat[:event_date], stat[:platform]]
      metrics = stat[:metrics] || {}

      Grovs::Events::MAPPING.each_value do |metric|
        grouped[key][metric] += metrics[metric] || 0
      end
    end

    rows = grouped.map do |(project_id, link_id, event_date, platform), metrics|
      {
        project_id: project_id,
        link_id: link_id,
        event_date: event_date,
        views: metrics[:views] || 0,
        opens: metrics[:opens] || 0,
        installs: metrics[:installs] || 0,
        reinstalls: metrics[:reinstalls] || 0,
        time_spent: metrics[:time_spent] || 0,
        revenue: metrics[:revenue] || 0,
        reactivations: metrics[:reactivations] || 0,
        app_opens: metrics[:app_opens] || 0,
        user_referred: metrics[:user_referred] || 0,
        platform: platform,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    if rows.any?
      # Sort by conflict key to prevent deadlocks between concurrent workers
      rows.sort_by! { |r| [r[:project_id], r[:link_id], r[:event_date].to_s, r[:platform].to_s] }
      bulk_increment_link_stats(rows)
    end
  end

  private

  def self.bulk_increment_link_stats(rows)
    BulkUpsertHelper.execute(
      table: "link_daily_statistics",
      rows: rows,
      columns: COLUMNS,
      conflict_keys: CONFLICT_KEYS,
      metric_columns: LinkDailyStatistic::METRIC_COLUMNS
    )
  end
end
