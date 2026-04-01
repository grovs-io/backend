class LinkStatisticsQuery
  SORTABLE_LINK_FIELDS = %w[name created_at updated_at tags].freeze
  SORTABLE_METRIC_FIELDS = %w[
    views opens installs reinstalls time_spent
    reactivations app_opens user_referred revenue
  ].freeze

  attr_reader :params, :project, :campaign_id

  def initialize(params: nil, project: nil, campaign_id: nil)
    @params = params
    @project = project
    @campaign_id = campaign_id
  end

  def call
    query = build_query.order(order_clause)

    per = all ? [build_query.count("links.id").length, 1].max : per_page
    paginated = query.page(page).per(per)

    {
      links: LinkSerializer.serialize(paginated, slim: true),
      meta: {
        page: page,
        total_pages: paginated.total_pages,
        per_page: paginated.limit_value,
        total_entries: paginated.total_count
      }
    }
  end

  private

  def build_query
    join_conditions = [
      "link_daily_statistics.link_id = links.id",
      "link_daily_statistics.event_date BETWEEN ? AND ?"
    ]
    bind_values = [start_date.beginning_of_day, end_date.end_of_day]

    if platform
      join_conditions << "link_daily_statistics.platform = ?"
      bind_values << platform
    end

    join_sql = ActiveRecord::Base.send(
      :sanitize_sql_array,
      ["LEFT OUTER JOIN link_daily_statistics ON #{join_conditions.join(' AND ')}", *bind_values]
    )

    query = Link.joins(join_sql)

    query = query.where(domain_id: project.domain.id) if project
    query = query.where(campaign_id: campaign_id) if campaign_id
    query = query.where(sdk_generated: sdk_filter) unless sdk_filter.nil?
    query = query.where(active: active)
    query = query.where(links: { id: link_id }) if link_id

    if term.present?
      query = query.where(
        "links.name ILIKE :t OR links.title ILIKE :t OR links.subtitle ILIKE :t OR links.path ILIKE :t OR EXISTS (
          SELECT 1 FROM unnest(links.tags) AS tag WHERE tag ILIKE :t
        )",
        t: "%#{term}%"
      )
    end

    query
      .group("links.id")
      .select(select_fields)
  end

  def order_clause
    if SORTABLE_LINK_FIELDS.include?(sort_by)
      "links.#{sort_by} #{direction}"
    elsif SORTABLE_METRIC_FIELDS.include?(sort_by)
      Arel.sql("SUM(COALESCE(link_daily_statistics.#{sort_by}, 0)) #{direction}")
    else
      "links.created_at DESC"
    end
  end

  def select_fields
    <<~SQL.squish
      links.*,
      COALESCE(SUM(link_daily_statistics.views), 0) AS total_views,
      COALESCE(SUM(link_daily_statistics.opens), 0) AS total_opens,
      COALESCE(SUM(link_daily_statistics.installs), 0) AS total_installs,
      COALESCE(SUM(link_daily_statistics.reinstalls), 0) AS total_reinstalls,
      COALESCE(SUM(link_daily_statistics.time_spent)::bigint, 0) AS total_time_spent,
      COALESCE(SUM(link_daily_statistics.reactivations), 0) AS total_reactivations,
      COALESCE(SUM(link_daily_statistics.app_opens), 0) AS total_app_opens,
      COALESCE(SUM(link_daily_statistics.user_referred), 0) AS total_user_referred,
      COALESCE(SUM(link_daily_statistics.revenue)::bigint, 0) AS total_revenue
    SQL
  end

  # Params helpers
  def page        = (params[:page] || 1).to_i
  def per_page    = [(params[:per_page] || 20).to_i, 1].max
  def sort_by     = params[:sort_by].to_s
  def term        = params[:term]
  def start_date  = (params[:start_date] || 30.days.ago).to_date
  def end_date    = (params[:end_date] || Date.today).to_date
  def date_range  = start_date.beginning_of_day..end_date.end_of_day
  def active      = params.fetch(:active, true)
  def link_id     = params[:link_id].presence
  def platform    = params[:platform].presence
  def all         = ActiveModel::Type::Boolean.new.cast(params[:all])

  def sdk_filter
    return nil unless params.key?(:sdk)
    ActiveModel::Type::Boolean.new.cast(params[:sdk])
  end

  def direction
    ActiveModel::Type::Boolean.new.cast(params[:ascendent]) ? 'asc' : 'desc'
  end
end