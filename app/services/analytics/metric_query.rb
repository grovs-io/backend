# frozen_string_literal: true

module Analytics
  # Validated shape of one GET analytics/query request; emits SQL fragments, runs nothing.
  class MetricQuery
    class Invalid < StandardError; end

    OTHER_KEY = '__other__'
    ALL_KEY = 'all'
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 50

    COUNTERS = {
      'events' => [nil, false],
      'views' => [Grovs::Events::VIEW, false],
      'link_views' => [Grovs::Events::VIEW, true],
      'opens' => [Grovs::Events::OPEN, false],
      'installs' => [Grovs::Events::INSTALL, false],
      'link_driven_installs' => [Grovs::Events::INSTALL, true],
      'reinstalls' => [Grovs::Events::REINSTALL, false],
      'app_opens' => [Grovs::Events::APP_OPEN, false],
      'referred_users' => [Grovs::Events::USER_REFERRED, false]
    }.freeze
    UNIQUES = { 'unique_visitors' => %w[visitor_id visitors_state], 'unique_devices' => %w[device_id devices_state] }.freeze
    METRICS = (COUNTERS.keys + UNIQUES.keys).freeze

    DIMENSIONS = %w[platform country city os os_version device_model app_version event_name screen_name
                    link_id campaign_id source tracking_source tracking_medium tracking_campaign
                    ads_platform language].freeze
    ID_DIMENSIONS = %w[link_id campaign_id].freeze

    # Rollup coverage: typed tables carry event_type (counters); untyped ones serve uniques only.
    ROLLUPS = {
      nil => { table: 'project_daily', dim: nil, typed: true, devices: true },
      'platform' => { table: 'project_daily', dim: 'platform', typed: true, devices: true },
      'country' => { table: 'project_country_daily', dim: 'country', typed: true },
      'app_version' => { table: 'project_version_daily', dim: 'app_version', typed: false },
      'source' => { table: 'project_source_daily', dim: 'source', typed: false },
      'properties.plan' => { table: 'project_property_daily', dim: 'property_value', typed: true, where: "property_key = 'plan'" },
      'properties.tier' => { table: 'project_property_daily', dim: 'property_value', typed: true, where: "property_key = 'tier'" }
    }.freeze

    attr_reader :metric, :group_by, :granularity, :limit, :compare, :start_day, :end_day, :resolved, :cutoff

    def self.build(params, start_date:, end_date:, platform: nil, cutoff: nil)
      metric = params[:metric].to_s
      raise Invalid, "metric must be one of #{METRICS.join(', ')}" unless METRICS.include?(metric)

      group_by = params[:group_by].presence&.to_s
      raise Invalid, 'unknown group_by' if group_by && !valid_dimension?(group_by)

      granularity = params[:granularity].presence&.to_s
      raise Invalid, 'granularity must be day, week or month' if granularity && !TimeBuckets::GRANULARITIES.include?(granularity)

      limit = params[:limit].present? ? Integer(params[:limit], exception: false) : DEFAULT_LIMIT
      raise Invalid, "limit must be between 1 and #{MAX_LIMIT}" unless limit&.between?(1, MAX_LIMIT)

      new(metric: metric, group_by: group_by, granularity: granularity, limit: limit,
          compare: ActiveModel::Type::Boolean.new.cast(params[:compare]) == true,
          start_day: start_date.to_date.strftime('%Y-%m-%d'), end_day: end_date.to_date.strftime('%Y-%m-%d'),
          resolved: OverviewFilters.resolve(params[:filters], platform: platform), cutoff: cutoff&.to_date)
    end

    def self.valid_dimension?(dim)
      return true if DIMENSIONS.include?(dim)
      return EventsQueryService.valid_property_key?(dim.delete_prefix('properties.')) if dim.start_with?('properties.')
      return EventsQueryService.valid_property_key?(dim.delete_prefix('user.')) if dim.start_with?('user.')

      false
    end

    def initialize(metric:, group_by:, granularity:, limit:, compare:, start_day:, end_day:, resolved:, cutoff: nil)
      @metric = metric
      @group_by = group_by
      @granularity = granularity
      @limit = limit
      @compare = compare
      @start_day = start_day
      @end_day = end_day
      @resolved = resolved
      @cutoff = cutoff
    end

    def prev_start_day
      span = Date.parse(end_day) - Date.parse(start_day)
      [Date.parse(start_day) - span - 1, cutoff].compact.max.strftime('%Y-%m-%d')
    end

    def prev_end_day
      (Date.parse(start_day) - 1).strftime('%Y-%m-%d')
    end

    def counter?
      COUNTERS.key?(metric)
    end

    def rollup
      return nil if resolved.raw?
      return nil if metric == 'events'

      r = ROLLUPS[group_by]
      return nil unless r
      return nil if COUNTERS.key?(metric) && COUNTERS[metric][1]
      return nil if metric == 'unique_devices' && !r[:devices]
      return nil if !r[:typed] && !UNIQUES.key?(metric)

      r
    end

    def raw?
      rollup.nil?
    end

    def windows
      TimeBuckets.windows(start_day, end_day, granularity || 'day')
    end

    def window_sql(date_expr)
      sd = "toDate('#{start_day}')"
      case granularity
      when 'day' then "dateDiff('day', #{sd}, #{date_expr})"
      when 'week' then "intDiv(dateDiff('day', #{sd}, #{date_expr}), 7)"
      when 'month'
        return '0' if windows.size <= 1

        bounds = windows[0..-2].each_with_index.map { |(_, to), i| "#{date_expr} <= toDate('#{to}'), #{i}" }
        "multiIf(#{bounds.join(', ')}, #{windows.size - 1})"
      end
    end

    def cache_key
      Digest::SHA1.hexdigest([metric, group_by, granularity, limit, compare, start_day, end_day,
                              resolved.platform, resolved.digest, cutoff].join('|'))[0, 16]
    end

    def plan(pid, previous: false)
      sd = previous ? prev_start_day : start_day
      ed = previous ? prev_end_day : end_day
      r = rollup
      r ? rollup_plan(pid, r, sd, ed) : raw_plan(pid, sd, ed)
    end

    private

    def raw_plan(pid, from_day, to_day)
      from = metric == 'unique_visitors' ? OverviewRawEvents.source_with_identity(pid, from_day) : OverviewRawEvents.source(pid, from_day)
      { from: from,
        where: OverviewRawEvents.where(pid, from_day, to_day, resolved.clauses + platform_clauses + metric_clauses + group_clauses),
        dim: raw_dimension_sql, agg: raw_agg_sql, date_expr: 'toDate(created_at)' }
    end

    # A rollup-mode resolve carries platform outside clauses, so a raw fallback must add it back.
    def platform_clauses
      return [] if resolved.raw? || resolved.platform.blank?

      EventsQueryService.filter_clauses([{ 'field' => 'platform', 'operator' => 'is', 'value' => resolved.platform }])
    end

    # Rollups hold events only, so uniques skip purchases unless a filter asks for them.
    def metric_clauses
      if UNIQUES.key?(metric)
        return [Grovs::Events::NOT_A_MESSAGE_SQL] if resolved.purchases

        return ["event_type != 'purchase'", Grovs::Events::NOT_A_MESSAGE_SQL]
      end

      c = COUNTERS[metric]
      return [] unless c

      clauses = []
      clauses << "event_type = '#{c[0]}'" if c[0]
      clauses << 'link_id > 0' if c[1]
      clauses
    end

    # The property rollup only stores events carrying the property, so raw breakdowns match it.
    def group_clauses
      group_by&.start_with?('properties.') ? ["#{raw_dimension_sql} != ''"] : []
    end

    def rollup_plan(pid, cfg, from_day, to_day)
      where = ["project_id = #{Integer(pid)}", "event_date >= '#{from_day}'", "event_date <= '#{to_day}'"]
      if resolved.platform.present?
        value = QueryHelpers.sanitize_string(ClickhouseReadService.normalize_platform_value(resolved.platform))
        where << "#{ClickhouseReadService::NORMALIZED_PLATFORM_SQL} = '#{value}'"
      end
      where << cfg[:where] if cfg[:where]
      dim = cfg[:dim] == 'platform' ? ClickhouseReadService::NORMALIZED_PLATFORM_SQL : (cfg[:dim] || "''")
      { from: cfg[:table], where: where.join(' AND '), dim: dim, agg: rollup_agg_sql, date_expr: 'event_date' }
    end

    def raw_dimension_sql
      case group_by
      when nil then "''"
      when 'platform' then ClickhouseReadService::NORMALIZED_PLATFORM_SQL
      when 'source' then SourceTaxonomy.expr
      when *ID_DIMENSIONS then "toString(#{group_by})"
      else
        if group_by.start_with?('properties.') then "CAST(properties.`#{group_by.delete_prefix('properties.')}` AS String)"
        elsif group_by.start_with?('user.') then "CAST(sdk_attributes.`#{group_by.delete_prefix('user.')}` AS String)"
        else group_by
        end
      end
    end

    def raw_agg_sql
      return 'count()' if counter?

      col = metric == 'unique_visitors' ? OverviewRawEvents::EFFECTIVE_VISITOR_SQL : UNIQUES.fetch(metric)[0]
      "uniqIf(#{col}, #{col} > 0)"
    end

    def rollup_agg_sql
      if (c = COUNTERS[metric])
        "sumIf(cnt, event_type = '#{c[0]}')"
      else
        "uniqMerge(#{UNIQUES.fetch(metric)[1]})"
      end
    end
  end
end
