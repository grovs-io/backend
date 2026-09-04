class VisitorReferralStatisticsQuery < VisitorStatisticsQueryBase
  SORTABLE_VISITOR_FIELDS = %w[sdk_identifier uuid created_at updated_at].freeze
  # Inviter columns CH has no copy of: PG orders, CH supplies population + metrics.
  PG_ORDERED_FIELDS = %w[sdk_identifier uuid updated_at].freeze

  def call
    if Clickhouse.analytics_rollups_read_enabled? && ch_orderable?
      ch = ch_call
      return ch if ch
    end

    result = super
    # Skipped on an invited-revenue SORT so order and displayed values stay consistent.
    if RevenueLedger.reads_enabled? && project && sort_by != "revenue"
      overlay_ledger_invited_revenue(result)
    end
    result
  end

  private

  def sortable_visitor_fields = SORTABLE_VISITOR_FIELDS
  def pg_ordered_fields = PG_ORDERED_FIELDS
  def ch_metric_prefix = "invited_"
  def ch_hydration_scope = Visitor.where(project_id: project.id)

  # Population comes from CH: the rollup groups the EVENT-TIME inviter, not visitors.inviter_id.
  # Over-cap is decided on the CH population, BEFORE PG drops merged/deleted inviters —
  # otherwise enough stale ids could pull the survivor count under the cap and serve a
  # silently truncated population instead of falling back.
  def candidate_scope
    scope = Visitor.where(project_id: project.id)
    # A detail lookup already knows the id; term_scope scopes it and CH filters inviter_id
    # IN (id), so the project-wide population scan buys nothing.
    unless visitor_id
      ids = ch_inviter_population
      return nil if ids.nil?
      return Clickhouse.id_cap_exceeded!(:inviter_population, term_id_cap) if ids.size > term_id_cap

      scope = scope.where(id: ids)
    end
    return scope unless platform

    # PG filters the INVITER's own device platform; matching it keeps the population
    # identical across the flag. The metrics stay all-platform, as on the PG path.
    scope.joins(:device).where(
      Arel::Nodes::NamedFunction.new("LOWER", [devices[:platform]]).eq(platform.downcase)
    )
  end

  # A merged-away inviter is deleted in PG but lives in the rollup, so CH must not page it.
  def restrict_to_candidate_ids? = true
  # Only true when the ids actually came from CH — a visitor_id lookup skips that query.
  def candidate_scope_from_ch? = visitor_id.blank?

  def ch_active_ids(ids)
    ClickhouseReadService.inviter_active_ids(
      project.id, inviter_ids: ids, start_date: start_date, end_date: end_date
    )
  end

  def ch_inviter_population
    return @ch_inviter_population if defined?(@ch_inviter_population)

    @ch_inviter_population = ClickhouseReadService.inviter_population_ids(
      project.id, start_date: start_date, end_date: end_date, limit: term_id_cap + 1
    )
  end

  # No platform filter: PG sums invited metrics across every platform, and the population
  # is already scoped to inviters on this platform by candidate_scope.
  def ch_metrics_page(order:, direction:, limit:, offset:, ids:)
    ClickhouseReadService.inviter_metrics_page(
      project.id, start_date: start_date, end_date: end_date,
      order: order, direction: direction,
      limit: limit, offset: offset, inviter_ids: ids
    )
  end

  # All-platform, matching the metrics beside it and the PG path.
  def ch_page_revenue(page_ids)
    if RevenueLedger.reads_enabled?
      ledger = RevenueLedgerQuery.by_inviter(
        project.id, inviter_ids: page_ids, start_date: start_date, end_date: end_date
      )
      return ledger unless ledger.nil?
    end

    VisitorDailyStatistic.where(project_id: project.id, invited_by_id: page_ids,
                                event_date: date_range)
                         .group(:invited_by_id).sum(:revenue)
  end

  # Only revenue moves to the ledger; an invited_revenue SORT still orders by stat sums.
  def overlay_ledger_invited_revenue(result)
    rows = result[:visitors]
    return if rows.blank?

    ledger = RevenueLedgerQuery.by_inviter(
      project.id, inviter_ids: rows.map { |r| r["id"] },
      start_date: start_date, end_date: end_date
    )
    return if ledger.nil?

    rows.each { |r| r["invited_revenue"] = ledger.fetch(r["id"], 0) }
  end

  def apply_joins(scope)
    scope.left_joins(:referral_daily_statistics, :device)
  end

  def apply_project_scope(query)
    query = query.where(visitors: { project_id: project.id }) if project
    query
  end

  def group_columns
    [visitors[:id]]
  end

  def select_fields
    zero = Arel.sql("0")
    aggregates = VisitorDailyStatistic::METRIC_COLUMNS.map do |col|
      sum_expr = stats[col].sum
      if BIGINT_CAST_COLUMNS.include?(col)
        Arel.sql("COALESCE((#{sum_expr.to_sql})::bigint, 0) AS invited_#{col}")
      else
        coalesced = Arel::Nodes::NamedFunction.new("COALESCE", [sum_expr, zero])
        coalesced.as("invited_#{col}")
      end
    end

    [
      visitors[Arel.star],
      *aggregates
    ]
  end

  def metric_order_expression
    coalesce = Arel::Nodes::NamedFunction.new("COALESCE", [stats[sort_by.to_sym], Arel.sql("0")])
    direction == "asc" ? coalesce.sum.asc : coalesce.sum.desc
  end

  # Legacy paginated query (OLD API). Joins events via links instead of
  # using pre-aggregated daily stats.
  ALLOWED_LEGACY_SORT_COLUMNS = (Grovs::Events::ALL + %w[created_at updated_at]).freeze

  def self.paginated_aggregated_events(page:, event_type:, asc:, project:, start_date:, end_date:, term: nil, per_page: nil)
    v = Visitor.arel_table
    direction = asc ? :asc : :desc
    event_type = "created_at" unless event_type.present? && ALLOWED_LEGACY_SORT_COLUMNS.include?(event_type)

    query = aggregated_events_per_visitor(project.id)
                .for_project(project.id)
                .where(v[:updated_at].between(start_date.beginning_of_day..end_date.end_of_day))

    if term.present?
      pat = "%#{term}%"
      query = query.where(
        Arel.sql("visitors.uuid::text").matches(pat)
          .or(v[:sdk_identifier].matches(pat))
      )
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

  def self.aggregated_events_per_visitor(project_id)
    v = Visitor.arel_table
    l = Link.arel_table
    e = Event.arel_table
    d = Device.arel_table

    join_sources = v
      .join(l, Arel::Nodes::OuterJoin).on(l[:visitor_id].eq(v[:id]))
      .join(e, Arel::Nodes::OuterJoin).on(
        e[:link_id].eq(l[:id]).and(e[:project_id].eq(project_id))
      )
      .join(d, Arel::Nodes::OuterJoin).on(d[:id].eq(v[:device_id]))
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
  private_class_method :aggregated_events_per_visitor
end
