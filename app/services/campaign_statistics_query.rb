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
    if Clickhouse.analytics_rollups_read_enabled?
      ch_call || pg_call
    else
      pg_call
    end
  end

  private

  # Campaigns + revenue from PG, metrics from link_daily (event-time campaign
  # attribution); merged/sorted in Ruby (low cardinality). nil → PG fallback.
  def ch_call
    ch_rows = ClickhouseReadService.campaign_metrics_daily(
      project.id, start_date: start_date, end_date: end_date, platform: platform
    )
    return nil if ch_rows.nil?

    campaigns = base_campaigns.to_a
    metrics = ch_rows.index_by { |r| r["campaign_id"].to_i }
    revenue = revenue_by_campaign(campaigns.map(&:id))

    rows = campaigns.map do |campaign|
      m = metrics[campaign.id] || {}
      totals = CH_COVERED_METRICS.to_h { |k| ["total_#{k}", m[k].to_i] }
      totals["total_revenue"] = revenue.fetch(campaign.id, 0).to_i
      [campaign, totals]
    end

    sorted = sort_rows(rows)
    offset = (page - 1) * per_page
    page_records = (sorted[offset, per_page] || []).map do |campaign, totals|
      Campaign.instantiate(campaign.attributes.merge(totals))
    end

    Kaminari.paginate_array(page_records, total_count: rows.size, limit: per_page, offset: offset)
  end

  def pg_call
    # Build join conditions for link_daily_statistics.
    # project_id is required in the join: a LinkDailyStatistic row is keyed by the
    # EVENT's project, so an event that referenced a link from another project
    # would otherwise leak (link_id matches, wrong project). Scope to this project.
    join_conditions = [
      "link_daily_statistics.link_id = links.id",
      "link_daily_statistics.project_id = ?",
      "link_daily_statistics.event_date BETWEEN ? AND ?"
    ]
    bind_values = [project.id, start_date.beginning_of_day, end_date.end_of_day]

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
      .then { |paginated| overlay_pg_ledger_revenue(paginated) }
  end

  # Ledger-flagged PG path displays ledger revenue (revenue SORT skips the overlay
  # so order and values stay consistent; nil → keep stat values).
  def overlay_pg_ledger_revenue(paginated)
    return paginated unless RevenueLedger.reads_enabled? && sort_by != "revenue"

    ledger = RevenueLedgerQuery.by_campaigns(
      project.id, campaign_ids: paginated.map(&:id),
      start_date: start_date, end_date: end_date, platform: platform
    )
    return paginated if ledger.nil?

    records = paginated.map do |campaign|
      Campaign.instantiate(campaign.attributes.merge("total_revenue" => ledger.fetch(campaign.id, 0)))
    end
    Kaminari.paginate_array(records, total_count: paginated.total_count,
                                     limit: paginated.limit_value, offset: paginated.offset_value)
  end

  CH_COVERED_METRICS = ClickhouseReadService::ROLLUP_SORT_METRICS

  def base_campaigns
    Campaign.where(project_id: project.id)
            .yield_self { |q| filter_by_name(q) }
            .yield_self { |q| filter_by_archived(q) }
  end

  # Revenue via CURRENT links.campaign_id (PG stats carry no event-time campaign).
  # Ledger when flagged, stat table otherwise/fallback.
  def revenue_by_campaign(campaign_ids)
    return {} if campaign_ids.empty?

    if RevenueLedger.reads_enabled?
      ledger = RevenueLedgerQuery.by_campaigns(
        project.id, campaign_ids: campaign_ids,
        start_date: start_date, end_date: end_date, platform: platform
      )
      return ledger unless ledger.nil?
    end

    rel = LinkDailyStatistic
            .joins("INNER JOIN links ON links.id = link_daily_statistics.link_id")
            .where(project_id: project.id,
                   event_date: start_date.beginning_of_day..end_date.end_of_day)
            .where(links: { campaign_id: campaign_ids })
    rel = rel.where(platform: platform) if platform.present?
    rel.group("links.campaign_id").sum(:revenue)
  end

  # Mirrors the PG order_clause; ties broken by id for determinism.
  def sort_rows(rows)
    if SORTABLE_CAMPAIGN_FIELDS.include?(sort_by)
      sorted = rows.sort_by { |campaign, _| [campaign.public_send(sort_by), campaign.id] }
      direction == "desc" ? sorted.reverse : sorted
    elsif SORTABLE_METRIC_FIELDS.include?(sort_by)
      desc = direction == "desc"
      rows.sort_by { |campaign, totals| [desc ? -totals["total_#{sort_by}"] : totals["total_#{sort_by}"], campaign.id] }
    else
      rows.sort_by { |campaign, _| [campaign.created_at, campaign.id] }.reverse
    end
  end

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

  # FE sends `ascending`; `ascendent` kept for the legacy dashboard payloads.
  def direction
    raw = params[:ascendent]
    raw = params[:ascending] if raw.nil?
    ActiveModel::Type::Boolean.new.cast(raw) ? 'asc' : 'desc'
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