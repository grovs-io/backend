class CampaignStatisticsQuery
  SORTABLE_CAMPAIGN_FIELDS = %w[name created_at updated_at].freeze
  SORTABLE_METRIC_FIELDS = %w[
    views opens installs reinstalls time_spent
    reactivations app_opens user_referred revenue
  ].freeze

  attr_reader :project, :params

  def initialize(project:, params: {})
    @project = project
    @params = params
  end

  def call
    # Build join conditions for link_daily_statistics
    join_conditions = [
      "link_daily_statistics.link_id = links.id",
      "link_daily_statistics.event_date BETWEEN ? AND ?"
    ]
    bind_values = [start_date.beginning_of_day, end_date.end_of_day]

    if platform.present?
      join_conditions << "link_daily_statistics.platform = ?"
      bind_values << platform
    end

    stats_join = ActiveRecord::Base.send(
      :sanitize_sql_array,
      ["LEFT OUTER JOIN link_daily_statistics ON #{join_conditions.join(' AND ')}", *bind_values]
    )

    Campaign
      .joins("LEFT OUTER JOIN links ON links.campaign_id = campaigns.id")
      .joins(stats_join)
      .where(project_id: project.id)
      .yield_self { |q| filter_by_name(q) }
      .yield_self { |q| filter_by_archived(q) }
      .group("campaigns.id", "campaigns.name")
      .select(<<~SQL.squish)
        campaigns.*,
        COALESCE(SUM(link_daily_statistics.views), 0)         AS total_views,
        COALESCE(SUM(link_daily_statistics.opens), 0)         AS total_opens,
        COALESCE(SUM(link_daily_statistics.installs), 0)      AS total_installs,
        COALESCE(SUM(link_daily_statistics.reinstalls), 0)    AS total_reinstalls,
        COALESCE(SUM(link_daily_statistics.time_spent)::bigint, 0)    AS total_time_spent,
        COALESCE(SUM(link_daily_statistics.reactivations), 0) AS total_reactivations,
        COALESCE(SUM(link_daily_statistics.app_opens), 0)     AS total_app_opens,
        COALESCE(SUM(link_daily_statistics.user_referred), 0) AS total_user_referred,
        COALESCE(SUM(link_daily_statistics.revenue)::bigint, 0)       AS total_revenue
      SQL
      .order(order_clause)
      .page(page)
      .per(per_page)
  end

  private

  def start_date
    (params[:start_date] || 30.days.ago).to_date
  end

  def end_date
    (params[:end_date] || Date.today).to_date
  end

  def filter_by_name(query)
    return query unless params[:term].present?

    query.where("campaigns.name ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:term])}%")
  end

  def platform
    params[:platform].presence
  end

  def filter_by_archived(query)
    return query unless params.key?(:archived)

    query.where(archived: ActiveModel::Type::Boolean.new.cast(params[:archived]))
  end

  def sort_by
    params[:sort_by].to_s
  end

  def page
    (params[:page] || 1).to_i
  end

  def per_page
    [(params[:per_page] || 20).to_i, 1].max
  end

  def direction
    ActiveModel::Type::Boolean.new.cast(params[:ascendent]) ? 'asc' : 'desc'
  end

  def order_clause
    dir = direction
    if SORTABLE_CAMPAIGN_FIELDS.include?(sort_by)
      col = ActiveRecord::Base.connection.quote_column_name(sort_by)
      Arel.sql("campaigns.#{col} #{dir}")
    elsif SORTABLE_METRIC_FIELDS.include?(sort_by)
      col = ActiveRecord::Base.connection.quote_column_name(sort_by)
      Arel.sql("COALESCE(SUM(link_daily_statistics.#{col}), 0) #{dir}")
    else
      Arel.sql("campaigns.created_at DESC")
    end
  end
end