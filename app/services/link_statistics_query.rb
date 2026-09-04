class LinkStatisticsQuery
  SORTABLE_LINK_FIELDS = %w[name title path created_at updated_at tags active sdk_generated campaign_id ads_platform].freeze
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
    # Ledger revenue sort works with or without CH (page metrics fall back to PG).
    if RevenueLedger.reads_enabled? && sort_by == "revenue"
      return ledger_revenue_sort_call || pg_call
    end

    # Field sorts paginate on `links` + CH page metrics; metric sorts paginate in
    # the rollup; revenue sorts (ledger off) stay on the PG aggregate join.
    if Clickhouse.analytics_rollups_read_enabled?
      if !metric_sort?
        ch_call
      elsif sort_by == "revenue"
        pg_call
      else
        ch_metric_sort_call || pg_call
      end
    else
      pg_call
    end
  end

  private

  def pg_call
    query = build_query.order(order_clause)

    per = all ? [build_query.count("links.id").length, 1].max : per_page
    paginated = query.page(page).per(per)

    serialized = LinkSerializer.serialize(paginated, slim: true)
    # Ledger-flagged PG paths display ledger revenue; a revenue SORT skips the
    # overlay so order and values stay consistent (both stat-sourced there).
    overlay_ledger_revenue!(serialized) unless sort_by == "revenue"

    {
      links: serialized,
      meta: {
        page: page,
        total_pages: paginated.total_pages,
        per_page: paginated.limit_value,
        total_entries: paginated.total_count
      }
    }
  end

  def ch_call
    scoped = links_scope.order(link_order_clause)
    per = all ? [links_scope.count, 1].max : per_page
    paginated = scoped.page(page).per(per)

    metrics = page_metrics(paginated.map(&:id))
    serialized = LinkSerializer.serialize(paginated, slim: true).map do |link|
      link.merge(metrics.fetch(link["id"], ZERO_METRICS))
    end

    {
      links: serialized,
      meta: {
        page: page,
        total_pages: paginated.total_pages,
        per_page: paginated.limit_value,
        total_entries: paginated.total_count
      }
    }
  end

  METRIC_SORT_ID_CAP = Clickhouse::MAX_IN_LIST_IDS

  # No-activity links sort LAST for BOTH directions — deliberate ASC divergence from PG.
  def ch_metric_sort_call
    dim = dimension_metric_sort_call if Clickhouse.link_dimensions_read_enabled?
    return dim if dim

    ids = links_scope.limit(metric_sort_id_cap + 1).pluck(:id)
    return Clickhouse.id_cap_exceeded!(:link_metric_sort, metric_sort_id_cap) if ids.size > metric_sort_id_cap

    per = all ? [ids.size, 1].max : per_page
    offset = (page - 1) * per

    paged = narrow_metric_sort_page(ids, per, offset)
    return nil if paged.nil?

    render_metric_page(paged[0], paged[1], ids.size, per)
  end

  # Project-scoped: a moved link leaves a stale dimension key that would leak other metadata.
  def hydrate_links(page_ids)
    scope = Link.where(id: page_ids)
    scope = scope.where(domain_id: project.domain.id) if project
    scope.index_by(&:id)
  end

  def render_metric_page(page_ids, metrics_by_id, total, per)
    links_by_id = hydrate_links(page_ids)
    revenue = page_revenue(page_ids)
    serialized = page_ids.filter_map do |id|
      link = links_by_id[id]
      next unless link # PG-deleted but still in CH until next rebuild; totals briefly overcount

      covered = metrics_by_id[id] || {}
      LinkSerializer.serialize(link, slim: true)
                    .merge(COVERED_KEYS.to_h { |k| ["total_#{k}", covered[k].to_i] })
                    .merge("total_revenue" => revenue.fetch(id, 0).to_i)
    end

    {
      links: serialized,
      meta: {
        page: page,
        total_pages: (total / per.to_f).ceil,
        per_page: per,
        total_entries: total
      }
    }
  end

  # ClickHouse owns population, filter, order and pagination — no id list, so no cap.
  def dimension_metric_sort_call
    return nil unless project
    # `active` is nullable in Postgres and a nil filter there means IS NULL, which a UInt8
    # dimension column cannot express — fall back rather than silently widen the population.
    return nil if active.nil?

    # nil limit = no LIMIT clause: `all` must size itself from CH's count, not Postgres'.
    per = all ? nil : per_page
    result = ClickhouseReadService.link_page_from_dimensions(
      project.id, metric: sort_by, direction: direction,
      start_date: start_date, end_date: end_date, platform: platform,
      limit: per, offset: per ? (page - 1) * per : 0, filters: dimension_filters
    )
    return nil if result.nil?

    page_ids = result[:rows].map { |r| r["link_id"].to_i }
    metrics_by_id = result[:rows].each_with_object({}) do |r, h|
      h[r["link_id"].to_i] = COVERED_KEYS.index_with { |k| r[k.to_s].to_i }
    end

    render_metric_page(page_ids, metrics_by_id, result[:total], per || [result[:total], 1].max)
  end

  def dimension_filters
    {
      active: active,
      sdk_generated: sdk_filter,
      campaign_id: campaign_id,
      ads_platform: ads_platform,
      link_id: link_id,
      term: term
    }
  end

  def narrow_metric_sort_page(ids, per, offset)
    result = ClickhouseReadService.link_metrics_sorted_page(
      project&.id, link_ids: ids, metric: sort_by, direction: direction,
      start_date: start_date, end_date: end_date, platform: platform,
      limit: per, offset: offset
    )
    return nil if result.nil?

    page_ids = result[:rows].map { |r| r["link_id"].to_i }
    metrics_by_id = result[:rows].each_with_object({}) do |r, h|
      h[r["link_id"].to_i] = COVERED_KEYS.index_with { |k| r[k.to_s].to_i }
    end

    remaining = per - page_ids.size
    if remaining.positive? && ids.size > result[:active_count]
      tail = zero_tail_ids(ids, result[:active_count], offset, remaining)
      return nil if tail.nil?

      page_ids += tail
      return nil if merge_tail_metrics(metrics_by_id, tail).nil?
    end

    [page_ids, metrics_by_id]
  end

  # Zero-revenue links sort LAST both directions, tie id ASC; nil → PG aggregate fallback.
  def ledger_revenue_sort_call
    return nil unless project

    ids = links_scope.limit(metric_sort_id_cap + 1).pluck(:id)
    return Clickhouse.id_cap_exceeded!(:link_revenue_sort, metric_sort_id_cap) if ids.size > metric_sort_id_cap

    cents = RevenueLedgerQuery.by_link_ids(
      project.id, link_ids: ids,
      start_date: start_date, end_date: end_date, platform: platform
    )
    return nil if cents.nil?

    paying = cents.reject { |_, v| v.zero? }
    desc = direction == "desc"
    sorted = paying.sort_by { |id, v| [desc ? -v : v, id] } # tie-break id ASC both ways
    ordered = sorted.map(&:first) + (ids - paying.keys).sort

    per = all ? [ids.size, 1].max : per_page
    page_ids = ordered[(page - 1) * per, per] || []

    links_by_id = hydrate_links(page_ids)
    # Reuse the ordering map for display — one ledger query, values always match order.
    metrics = page_metrics(page_ids, revenue: cents)
    serialized = page_ids.filter_map do |id|
      link = links_by_id[id]
      link && LinkSerializer.serialize(link, slim: true).merge(metrics.fetch(id, ZERO_METRICS))
    end

    {
      links: serialized,
      meta: {
        page: page,
        total_pages: (ids.size / per.to_f).ceil,
        per_page: per,
        total_entries: ids.size
      }
    }
  end

  ZERO_METRICS = {
    "total_views" => 0, "total_opens" => 0, "total_installs" => 0, "total_reinstalls" => 0,
    "total_time_spent" => 0, "total_reactivations" => 0, "total_app_opens" => 0,
    "total_user_referred" => 0, "total_revenue" => 0
  }.freeze

  # The `links` filter set without any stats join (domain/campaign/sdk/active/id/term).
  def links_scope
    query = Link.all
    query = query.where(domain_id: project.domain.id) if project
    query = query.where(campaign_id: campaign_id) if campaign_id
    query = query.where(sdk_generated: sdk_filter) unless sdk_filter.nil?
    query = query.where(active: active)
    query = query.where(links: { id: link_id }) if link_id
    query = query.where(ads_platform: ads_platform) if ads_platform

    if term.present?
      sanitized_term = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
      query = query.where(
        "links.name ILIKE :t OR links.title ILIKE :t OR links.subtitle ILIKE :t OR links.path ILIKE :t OR EXISTS (
          SELECT 1 FROM unnest(links.tags) AS tag WHERE tag ILIKE :t
        )",
        t: sanitized_term
      )
    end
    query
  end

  # Link-column sort only (metric sorts never reach here). Falls back to created_at DESC.
  def link_order_clause
    dir = direction
    if SORTABLE_LINK_FIELDS.include?(sort_by)
      col = ActiveRecord::Base.connection.quote_column_name(sort_by)
      Arel.sql("links.#{col} #{dir}")
    else
      Arel.sql("links.created_at DESC")
    end
  end

  COVERED_KEYS = %i[views opens installs reinstalls time_spent reactivations app_opens user_referred].freeze

  # Covered metrics (CH rollup, or PG fallback when CH is unavailable) + revenue
  # (always PG), merged per link_id and keyed by the total_* aliases the serializer
  # and PG path emit.
  def page_metrics(link_ids, revenue: nil)
    return {} if link_ids.empty?

    covered = ch_covered_metrics(link_ids) || pg_covered_metrics(link_ids)
    revenue ||= page_revenue(link_ids)

    link_ids.each_with_object({}) do |id, h|
      c = covered[id] || {}
      h[id] = COVERED_KEYS.to_h { |k| ["total_#{k}", c[k].to_i] }
                          .merge("total_revenue" => revenue.fetch(id, 0).to_i)
    end
  end

  # nil when CH is unavailable so page_metrics falls back to PG.
  def ch_covered_metrics(link_ids)
    rows = ClickhouseReadService.link_metrics_by_id(
      project&.id, link_ids: link_ids,
      start_date: start_date, end_date: end_date, platform: platform
    )
    return nil if rows.nil?

    rows.each_with_object({}) do |r, h|
      h[r["link_id"].to_i] = COVERED_KEYS.index_with { |k| r[k.to_s].to_i }
    end
  end

  # PG fallback: covered metrics summed from link_daily_statistics for the page ids.
  def pg_covered_metrics(link_ids)
    rel = LinkDailyStatistic
            .where(project_id: project&.id, link_id: link_ids, event_date: start_date..end_date)
    rel = rel.where(platform: platform) if platform
    rel.group(:link_id)
       .pluck(:link_id, *COVERED_KEYS.map { |k| Arel.sql("SUM(#{k})") })
       .each_with_object({}) do |row, h|
      link_id, *sums = row
      h[link_id] = COVERED_KEYS.zip(sums.map(&:to_i)).to_h
    end
  end

  # Revenue never moves to CH: ledger when flagged, stat table otherwise/fallback.
  def page_revenue(link_ids)
    if RevenueLedger.reads_enabled? && project
      ledger = RevenueLedgerQuery.by_link_ids(
        project.id, link_ids: link_ids,
        start_date: start_date, end_date: end_date, platform: platform
      )
      return ledger unless ledger.nil?
    end

    rel = LinkDailyStatistic
            .where(project_id: project&.id, link_id: link_ids, event_date: start_date..end_date)
    rel = rel.where(platform: platform) if platform
    rel.group(:link_id).sum(:revenue)
  end

  def metric_sort? = SORTABLE_METRIC_FIELDS.include?(sort_by)

  def overlay_ledger_revenue!(rows)
    return unless RevenueLedger.reads_enabled? && project && rows.present?

    ledger = RevenueLedgerQuery.by_link_ids(
      project.id, link_ids: rows.map { |r| r["id"] },
      start_date: start_date, end_date: end_date, platform: platform
    )
    return if ledger.nil?

    rows.each { |r| r["total_revenue"] = ledger.fetch(r["id"], 0) }
  end

  # The tail is "zero for the SORTED metric", not "zero for everything" — without this a
  # link with 500 views serialises views=0 when you sort by installs.
  def merge_tail_metrics(metrics_by_id, tail)
    rows = ClickhouseReadService.link_metrics_by_id(
      project&.id, link_ids: tail, start_date: start_date, end_date: end_date, platform: platform
    )
    return nil if rows.nil?

    rows.each { |r| metrics_by_id[r["link_id"].to_i] = COVERED_KEYS.index_with { |k| r[k.to_s].to_i } }
    metrics_by_id
  end

  # Links with a zero value for the sorted metric, paged after the active ones.
  def zero_tail_ids(ids, active_count, offset, remaining)
    active_ids = ClickhouseReadService.link_active_ids(
      project&.id, link_ids: ids, metric: sort_by,
      start_date: start_date, end_date: end_date, platform: platform
    )
    return nil if active_ids.nil?

    (ids - active_ids).sort[[offset - active_count, 0].max, remaining] || []
  end

  # Method (not constant ref) so tests can stub the cap.
  def metric_sort_id_cap = METRIC_SORT_ID_CAP

  def build_query
    join_conditions = [
      "link_daily_statistics.link_id = links.id",
      "link_daily_statistics.event_date BETWEEN ? AND ?"
    ]
    bind_values = [start_date.beginning_of_day, end_date.end_of_day]

    # Scope the stats join to the project so a foreign-project event that
    # referenced one of this project's links can't inflate its totals
    # (link_daily rows are keyed by the event's project).
    if project
      join_conditions << "link_daily_statistics.project_id = ?"
      bind_values << project.id
    end

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
    query = query.where(ads_platform: ads_platform) if ads_platform

    if term.present?
      sanitized_term = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
      query = query.where(
        "links.name ILIKE :t OR links.title ILIKE :t OR links.subtitle ILIKE :t OR links.path ILIKE :t OR EXISTS (
          SELECT 1 FROM unnest(links.tags) AS tag WHERE tag ILIKE :t
        )",
        t: sanitized_term
      )
    end

    query
      .group("links.id")
      .select(select_fields)
  end

  def order_clause
    dir = direction
    if SORTABLE_LINK_FIELDS.include?(sort_by)
      col = ActiveRecord::Base.connection.quote_column_name(sort_by)
      Arel.sql("links.#{col} #{dir}")
    elsif SORTABLE_METRIC_FIELDS.include?(sort_by)
      col = ActiveRecord::Base.connection.quote_column_name(sort_by)
      Arel.sql("SUM(COALESCE(link_daily_statistics.#{col}, 0)) #{dir}")
    else
      Arel.sql("links.created_at DESC")
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
  # Cast: raw "false" is truthy in Ruby, which inverted the ClickHouse filter.
  def active
    raw = params.fetch(:active, true)
    raw.nil? ? nil : ActiveModel::Type::Boolean.new.cast(raw)
  end

  def link_id      = params[:link_id].presence
  def platform     = params[:platform].presence
  def ads_platform = params[:ads_platform].presence
  def all          = ActiveModel::Type::Boolean.new.cast(params[:all])

  def sdk_filter
    return nil unless params.key?(:sdk)
    ActiveModel::Type::Boolean.new.cast(params[:sdk])
  end

  # FE sends `ascending`; `ascendent` kept for the legacy dashboard payloads.
  def direction
    raw = params[:ascendent]
    raw = params[:ascending] if raw.nil?
    ActiveModel::Type::Boolean.new.cast(raw) ? 'asc' : 'desc'
  end
end