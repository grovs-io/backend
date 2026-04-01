class VisitorReferralStatisticsQuery < VisitorStatisticsQueryBase
  SORTABLE_VISITOR_FIELDS = %w[sdk_identifier uuid created_at updated_at].freeze

  private

  def sortable_visitor_fields = SORTABLE_VISITOR_FIELDS

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
