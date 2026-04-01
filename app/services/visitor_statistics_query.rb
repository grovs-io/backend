class VisitorStatisticsQuery < VisitorStatisticsQueryBase
  SORTABLE_VISITOR_FIELDS = %w[sdk_identifier uuid created_at].freeze

  private

  def sortable_visitor_fields = SORTABLE_VISITOR_FIELDS

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
