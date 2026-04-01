class VisitorStatisticsQueryBase
  SORTABLE_METRIC_FIELDS = VisitorDailyStatistic::METRIC_COLUMNS.map(&:to_s).freeze
  BIGINT_CAST_COLUMNS = %i[time_spent revenue].freeze

  attr_reader :params, :project

  def initialize(params: nil, project: nil)
    @params = params
    @project = project
  end

  def call
    paginated = build_query.order(order_clause).page(page).per(per_page)

    {
      visitors: VisitorSerializer.serialize(paginated, slim: true),
      meta: {
        page: page,
        total_pages: paginated.total_pages,
        per_page: paginated.limit_value,
        total_entries: paginated.total_count
      }
    }
  end

  private

  def visitors = Visitor.arel_table
  def stats    = VisitorDailyStatistic.arel_table
  def devices  = Device.arel_table

  def build_query
    query = apply_joins(Visitor)
    query = query.where(visitor_daily_statistics: { event_date: date_range })
    query = apply_project_scope(query)
    query = query.where(visitors: { id: visitor_id }) if visitor_id

    if term.present?
      pat = "%#{term}%"
      query = query.where(
        visitors[:sdk_identifier].matches(pat)
          .or(Arel.sql("visitors.uuid::text").matches(pat))
      )
    end

    if platform
      lower_platform = Arel::Nodes::NamedFunction.new("LOWER", [devices[:platform]])
      query = query.where(lower_platform.eq(platform.downcase))
    end

    query.group(*group_columns)
         .select(select_fields)
  end

  def order_clause
    if sortable_visitor_fields.include?(sort_by)
      direction == "asc" ? visitors[sort_by.to_sym].asc : visitors[sort_by.to_sym].desc
    elsif SORTABLE_METRIC_FIELDS.include?(sort_by)
      metric_order_expression
    else
      visitors[:created_at].desc
    end
  end

  # --- Template methods for subclasses ---

  def apply_joins(_scope)
    raise NotImplementedError
  end

  def apply_project_scope(query)
    raise NotImplementedError
  end

  def group_columns
    raise NotImplementedError
  end

  def select_fields
    raise NotImplementedError
  end

  def metric_order_expression
    raise NotImplementedError
  end

  def sortable_visitor_fields
    raise NotImplementedError
  end

  # --- Params helpers ---

  def page        = (params[:page] || 1).to_i
  def per_page    = [(params[:per_page] || 20).to_i, 1].max
  def sort_by     = params[:sort_by].to_s
  def term        = params[:term]
  def start_date  = (params[:start_date] || 30.days.ago).to_date
  def end_date    = (params[:end_date] || Date.today).to_date
  def date_range  = start_date.beginning_of_day..end_date.end_of_day
  def visitor_id  = params[:visitor_id].presence
  def platform    = params[:platform].presence

  def direction
    ActiveModel::Type::Boolean.new.cast(params[:ascendent]) ? "asc" : "desc"
  end
end
