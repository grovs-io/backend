class VisitorStatisticsQuery < VisitorStatisticsQueryBase
  SORTABLE_VISITOR_FIELDS = %w[sdk_identifier uuid created_at].freeze
  # Served from user_profiles, so the candidate id cap no longer gates these sorts.
  CH_IDENTITY_FIELDS = %w[sdk_identifier uuid].freeze
  PG_ORDERED_FIELDS = [].freeze

  def call
    if Clickhouse.analytics_rollups_read_enabled? && ch_orderable?
      ch = ch_call
      return ch if ch
    end

    result = super
    # PG paths display ledger revenue too; a revenue SORT skips the overlay so
    # order and values stay consistent (both stat-sourced until cutover).
    overlay_ledger_revenue!(result) unless sort_by == "revenue"
    result
  end

  private

  def sortable_visitor_fields = SORTABLE_VISITOR_FIELDS
  def pg_ordered_fields = PG_ORDERED_FIELDS
  def ch_identity_fields = CH_IDENTITY_FIELDS

  def ch_identity_page(order:, direction:, limit:, offset:, ids:)
    ClickhouseReadService.visitor_metrics_page_by_identity(
      project.id, start_date: start_date, end_date: end_date,
      order: order, direction: direction, platform: platform,
      limit: limit, offset: offset, visitor_ids: ids, term: term
    )
  end
  def ch_metric_prefix = "total_"
  def ch_hydration_scope = Visitor.includes(:device).where(project_id: project.id)

  def decorate_ch_row(row, visitor)
    row["platform"] = visitor.device&.platform
  end

  def ch_metrics_page(order:, direction:, limit:, offset:, ids:)
    ClickhouseReadService.visitor_metrics_page(
      project.id, start_date: start_date, end_date: end_date,
      order: order, direction: direction, platform: platform,
      limit: limit, offset: offset, visitor_ids: ids
    )
  end

  def ch_active_ids(ids)
    ClickhouseReadService.visitor_active_ids(
      project.id, visitor_ids: ids, start_date: start_date, end_date: end_date, platform: platform
    )
  end

  def ch_page_revenue(page_ids) = page_visitor_revenue(page_ids)

  def overlay_ledger_revenue!(result)
    return unless RevenueLedger.reads_enabled? && project

    rows = result[:visitors]
    return if rows.blank?

    ledger = RevenueLedgerQuery.by_visitor_ids(
      project.id, visitor_ids: rows.map { |r| r["id"] },
      start_date: start_date, end_date: end_date, platform: platform
    )
    return if ledger.nil?

    rows.each { |r| r["total_revenue"] = ledger.fetch(r["id"], 0) }
  end

  # Revenue never moves to CH: ledger when flagged, stat table otherwise/fallback.
  def page_visitor_revenue(page_ids)
    if RevenueLedger.reads_enabled?
      ledger = RevenueLedgerQuery.by_visitor_ids(
        project.id, visitor_ids: page_ids,
        start_date: start_date, end_date: end_date, platform: platform
      )
      return ledger unless ledger.nil?
    end

    rel = VisitorDailyStatistic.where(visitor_id: page_ids, event_date: date_range)
    rel = rel.where(platform: platform) if platform
    rel.group(:visitor_id).sum(:revenue)
  end

  def apply_joins(scope)
    scope.joins(:visitor_daily_statistics, :device)
  end

  def apply_project_scope(query)
    query = query.where(project_id: project.id) if project
    query
  end

  def group_columns
    [visitors[:id], devices[:platform]]
  end

  def select_fields
    aggregates = VisitorDailyStatistic::METRIC_COLUMNS.map do |col|
      if BIGINT_CAST_COLUMNS.include?(col)
        Arel.sql("(#{stats[col].sum.to_sql})::bigint AS total_#{col}")
      else
        stats[col].sum.as("total_#{col}")
      end
    end

    [
      visitors[Arel.star],
      devices[:platform].as("platform"),
      *aggregates
    ]
  end

  def metric_order_expression
    direction == "asc" ? stats[sort_by.to_sym].sum.asc : stats[sort_by.to_sym].sum.desc
  end

  # Legacy paginated query (OLD API). Joins events directly instead of
  # using pre-aggregated daily stats.
  ALLOWED_LEGACY_SORT_COLUMNS = (Grovs::Events::ALL + %w[created_at updated_at]).freeze

  def self.paginated_own_events(page:, event_type:, asc:, project:, start_date:, end_date:, term: nil, visitor_id: nil, per_page: nil)
    v = Visitor.arel_table
    direction = asc ? :asc : :desc
    event_type = "created_at" unless event_type.present? && ALLOWED_LEGACY_SORT_COLUMNS.include?(event_type)

    query = own_event_counts(project.id).for_project(project.id)

    if term.present?
      pat = "%#{term}%"
      query = query.where(
        Arel.sql("visitors.uuid::text").matches(pat)
          .or(v[:sdk_identifier].matches(pat))
      )
    end

    if visitor_id
      query = query.where(v[:id].eq(visitor_id))
    else
      query = query.where(v[:updated_at].between(start_date.beginning_of_day..end_date.end_of_day))
    end

    query = query.order(Arel.sql(event_type).send(direction))

    wrapped_query = Visitor.unscoped.from("(#{query.to_sql}) AS visitors_with_counts").select("*")
    wrapped_query = wrapped_query.page(page)
    wrapped_query = wrapped_query.per([per_page.to_i, 1].max) if per_page

    {
      metrics: wrapped_query,
      page: page,
      total_pages: wrapped_query.total_pages,
      per_page: wrapped_query.limit_value,
      total_entries: wrapped_query.total_count
    }
  end

  def self.own_event_counts(project_id)
    v = Visitor.arel_table
    d = Device.arel_table
    e = Event.arel_table

    join_sources = v
      .join(d, Arel::Nodes::OuterJoin).on(d[:id].eq(v[:device_id]))
      .join(e, Arel::Nodes::OuterJoin).on(
        e[:device_id].eq(d[:id]).and(e[:project_id].eq(project_id))
      )
      .join_sources

    event_selects = Grovs::Events::ALL.flat_map do |et|
      count_expr = Arel::Nodes::NamedFunction.new("COALESCE", [
        Arel::Nodes::NamedFunction.new("SUM", [
          Arel::Nodes::Case.new.when(e[:event].eq(et)).then(1).else(0)
        ]),
        Arel.sql("0")
      ])

      time_expr = Arel::Nodes::NamedFunction.new("COALESCE", [
        Arel::Nodes::NamedFunction.new("SUM", [
          Arel::Nodes::Case.new.when(e[:event].eq(et)).then(e[:engagement_time]).else(0)
        ]),
        Arel.sql("0")
      ])

      [count_expr.as("#{et}_count"), time_expr.as("#{et}_engagement_time")]
    end

    Visitor.select(v[Arel.star], d[:platform], *event_selects)
           .joins(join_sources)
           .group(v[:id], d[:platform])
  end
  private_class_method :own_event_counts
end
