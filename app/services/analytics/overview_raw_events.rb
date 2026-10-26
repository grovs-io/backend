# frozen_string_literal: true

module Analytics
  # Raw `events` read path for overview filters the daily rollups cannot serve.
  module OverviewRawEvents
    extend QueryHelpers

    COUNTER_COLUMNS = %w[views link_views opens installs link_driven_installs reinstalls app_opens referred_users].freeze

    # metric → [event_type, link_only]; organic_installs is derived from the two INSTALL rows.
    METRIC_DEFS = {
      'views' => [Grovs::Events::VIEW, false],
      'link_views' => [Grovs::Events::VIEW, true],
      'opens' => [Grovs::Events::OPEN, false],
      'installs' => [Grovs::Events::INSTALL, false],
      'link_driven_installs' => [Grovs::Events::INSTALL, true],
      'reinstalls' => [Grovs::Events::REINSTALL, false],
      'app_opens' => [Grovs::Events::APP_OPEN, false],
      'referred_users' => [Grovs::Events::USER_REFERRED, false]
    }.freeze

    # No FINAL: it defeats partition pruning; event_id is a content hash so dupes are only unmerged retries.
    def self.source(pid, start_day)
      EventsSource.sql(final: false, project_id: pid, start_sql: "#{start_day} 00:00:00.000")
    end

    EFFECTIVE_VISITOR_SQL = ClickhouseRollupRebuildService.effective_visitor_id_expr

    # The rollups' merged-visitor resolution, so a raw read counts a merged visitor once.
    def self.source_with_identity(pid, start_day)
      "#{source(pid, start_day)} AS events LEFT JOIN (SELECT from_visitor_id, to_visitor_id " \
        "FROM visitor_identity_map FINAL WHERE project_id = #{Integer(pid)}) " \
        "AS #{ClickhouseRollupRebuildService::IDENTITY_MAP_ALIAS} " \
        "ON events.visitor_id = #{ClickhouseRollupRebuildService::IDENTITY_MAP_ALIAS}.from_visitor_id"
    end

    # Half-open UTC day range on created_at, so the partition/order key prunes.
    def self.where(pid, start_day, end_day, clauses)
      next_day = (Date.parse(end_day) + 1).strftime('%Y-%m-%d')
      ["project_id = #{pid}",
       "created_at >= toDateTime64('#{start_day} 00:00:00.000', 3, 'UTC')",
       "created_at < toDateTime64('#{next_day} 00:00:00.000', 3, 'UTC')",
       *clauses].join("\n  AND ")
    end

    def self.counters(pid, start_day, end_day, clauses)
      e = Grovs::Events
      row = with_guard(<<~SQL).to_a.first || {}
        SELECT
          countIf(event_type = '#{e::VIEW}')                    AS views,
          countIf(event_type = '#{e::VIEW}' AND link_id > 0)    AS link_views,
          countIf(event_type = '#{e::OPEN}')                    AS opens,
          countIf(event_type = '#{e::INSTALL}')                 AS installs,
          countIf(event_type = '#{e::INSTALL}' AND link_id > 0) AS link_driven_installs,
          countIf(event_type = '#{e::REINSTALL}')               AS reinstalls,
          countIf(event_type = '#{e::APP_OPEN}')                AS app_opens,
          countIf(event_type = '#{e::USER_REFERRED}')           AS referred_users
        FROM #{source(pid, start_day)}
        WHERE #{where(pid, start_day, end_day, clauses)}
      SQL
      COUNTER_COLUMNS.to_h { |k| [k.to_sym, row[k].to_i] }
    end

    # Effective visitors with a countable, filter-matching event in range — feeds classify_users.
    def self.visitor_set(pid, start_day, end_day, clauses)
      <<~SQL
        SELECT DISTINCT #{EFFECTIVE_VISITOR_SQL} AS effective_visitor_id
        FROM #{source_with_identity(pid, start_day)}
        WHERE #{where(pid, start_day, end_day, clauses)}
          AND #{EFFECTIVE_VISITOR_SQL} > 0
          AND event_type IN #{ClickhouseRollupRebuildService::COUNTABLE_TYPES_SQL}
      SQL
    end

    def self.metric_by_day(metric, pid, start_day, end_day, clauses)
      if metric == 'organic_installs'
        installs = daily_counts(pid, start_day, end_day, clauses, Grovs::Events::INSTALL, link_only: false)
        link = daily_counts(pid, start_day, end_day, clauses, Grovs::Events::INSTALL, link_only: true)
        return installs.to_h { |day, value| [day, [value - link.fetch(day, 0), 0].max] }
      end

      event_type, link_only = METRIC_DEFS.fetch(metric)
      daily_counts(pid, start_day, end_day, clauses, event_type, link_only: link_only)
    end

    def self.daily_counts(pid, start_day, end_day, clauses, event_type, link_only:)
      rows = with_guard(<<~SQL).to_a
        SELECT toDate(created_at) AS event_date, count() AS value
        FROM #{source(pid, start_day)}
        WHERE #{where(pid, start_day, end_day, clauses)}
          AND event_type = '#{event_type}'
          #{link_only ? 'AND link_id > 0' : ''}
        GROUP BY event_date
        ORDER BY event_date
      SQL
      rows.to_h { |r| [r['event_date'].to_s[0..9], r['value'].to_i] }
    end
  end
end
