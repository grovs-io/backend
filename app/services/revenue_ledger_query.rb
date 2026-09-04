# frozen_string_literal: true

# Empty is a real zero here; nil means the query failed (see guarded).
module RevenueLedgerQuery
  REVENUE_DELTA_SQL = <<~SQL.squish.freeze
    CASE
      WHEN event_type IN ('#{Grovs::Purchases::EVENT_BUY}', '#{Grovs::Purchases::EVENT_REFUND_REVERSED}')
        THEN usd_price_cents * quantity
      WHEN event_type = '#{Grovs::Purchases::EVENT_REFUND}'
        THEN -(usd_price_cents * quantity)
      WHEN event_type = '#{Grovs::Purchases::EVENT_CANCEL}'
           AND purchase_type IS DISTINCT FROM '#{Grovs::Purchases::TYPE_SUBSCRIPTION}'
        THEN -(usd_price_cents * quantity)
      ELSE 0
    END
  SQL

  UNITS_SOLD_SQL = <<~SQL.squish.freeze
    CASE WHEN event_type IN ('#{Grovs::Purchases::EVENT_BUY}', '#{Grovs::Purchases::EVENT_REFUND_REVERSED}')
      THEN quantity ELSE 0 END
  SQL

  CANCELLATIONS_SQL = <<~SQL.squish.freeze
    CASE WHEN event_type = '#{Grovs::Purchases::EVENT_CANCEL}'
           OR (event_type = '#{Grovs::Purchases::EVENT_REFUND}'
               AND purchase_type IS DISTINCT FROM '#{Grovs::Purchases::TYPE_SUBSCRIPTION}')
      THEN quantity ELSE 0 END
  SQL

  def self.by_link_ids(project_id, link_ids:, start_date:, end_date:, platform: nil)
    return {} if link_ids.empty?

    guarded(:by_link_ids) do
      revenue_map(base(project_id, start_date, end_date, platform).where(link_id: link_ids).group(:link_id))
    end
  end

  def self.by_visitor_ids(project_id, visitor_ids:, start_date:, end_date:, platform: nil)
    return {} if visitor_ids.empty?

    guarded(:by_visitor_ids) do
      revenue_map(base(project_id, start_date, end_date, platform).where(visitor_id: visitor_ids).group(:visitor_id))
    end
  end

  # Campaign revenue via the CURRENT links.campaign_id mapping (the ledger's link_id
  # snapshot is event-time, but campaigns own links, not purchases). A deleted link's
  # revenue leaves campaign totals (INNER JOIN) — same as today, where the link's stat
  # rows are destroyed with it; per-link ledger reads still retain it.
  def self.by_campaigns(project_id, campaign_ids:, start_date:, end_date:, platform: nil)
    return {} if campaign_ids.empty?

    guarded(:by_campaigns) do
      revenue_map(
        base(project_id, start_date, end_date, platform)
          .joins("INNER JOIN links ON links.id = purchase_events.link_id")
          .where(links: { campaign_id: campaign_ids })
          .group("links.campaign_id")
      )
    end
  end

  # Full per-link map for revenue SORTS — only links with purchases appear (small set).
  def self.revenue_by_link(project_id, start_date:, end_date:, platform: nil)
    guarded(:revenue_by_link) do
      revenue_map(base(project_id, start_date, end_date, platform).where.not(link_id: nil).group(:link_id))
    end
  end

  # Full per-visitor map for revenue SORTS.
  def self.revenue_by_visitor(project_id, start_date:, end_date:, platform: nil)
    guarded(:revenue_by_visitor) do
      revenue_map(base(project_id, start_date, end_date, platform).where.not(visitor_id: nil).group(:visitor_id))
    end
  end

  # Invited/referral revenue: purchases of visitors whose inviter is in inviter_ids.
  # Attribution follows the CURRENT visitors.inviter_id (set once at install; merges
  # repoint it) — deliberate: no event-time inviter snapshot until a product need shows.
  def self.by_inviter(project_id, inviter_ids:, start_date:, end_date:)
    return {} if inviter_ids.empty?

    guarded(:by_inviter) do
      revenue_map(
        base(project_id, start_date, end_date, nil)
          .joins("INNER JOIN visitors ON visitors.id = purchase_events.visitor_id")
          .where(visitors: { inviter_id: inviter_ids })
          .group("visitors.inviter_id")
      )
    end
  end

  def self.project_totals(project_id, start_date:, end_date:, platform: nil)
    guarded(:project_totals) do
      row = base(project_id, start_date, end_date, platform)
            .pick(
              Arel.sql("COALESCE(SUM(#{REVENUE_DELTA_SQL}), 0)"),
              Arel.sql("COALESCE(SUM(#{UNITS_SOLD_SQL}), 0)"),
              Arel.sql("COALESCE(SUM(#{CANCELLATIONS_SQL}), 0)")
            )
      { revenue: row[0].to_i, units_sold: row[1].to_i, cancellations: row[2].to_i }
    end
  end

  # { Date => cents }. App TZ is UTC, so date::date matches the Ruby .to_date bucketing.
  def self.daily_series(project_id, start_date:, end_date:, platform: nil)
    guarded(:daily_series) do
      base(project_id, start_date, end_date, platform)
        .group(Arel.sql("(date)::date"))
        .sum(Arel.sql(REVENUE_DELTA_SQL))
        .transform_keys(&:to_date)
        .transform_values(&:to_i)
    end
  end

  # Event-time earliest buy per (device, product) in range — deliberately differs
  # from legacy processing-order classification (documented tolerance).
  def self.first_time_purchases(project_id, start_date:, end_date:, platform: nil)
    guarded(:first_time_purchases) do
      # Literal predicates (not binds): a generic prepared plan can't prove bound
      # values imply the partial index predicate — literals keep the index usable.
      firsts = PurchaseEvent
               .select("DISTINCT ON (device_id, product_id) date, revenue_platform")
               .where(project_id: project_id)
               .where("processed AND event_type IN ('#{Grovs::Purchases::EVENT_BUY}', " \
                      "'#{Grovs::Purchases::EVENT_REFUND_REVERSED}') AND device_id IS NOT NULL " \
                      "AND product_id IS NOT NULL AND product_id != ''")
               .order("device_id, product_id, date ASC, id ASC")

      rel = PurchaseEvent.from(firsts, :firsts)
                         .where("firsts.date BETWEEN ? AND ?",
                                start_date.to_date.beginning_of_day, end_date.to_date.end_of_day)
      rel = rel.where("firsts.revenue_platform IN (?)", Array(platform)) if platform.present?
      rel.count
    end
  end

  def self.product_totals(project_id, start_date:, end_date:, platform: nil, product_filter: nil)
    guarded(:product_totals, warm_fallback: true) do
      sql = product_totals_sql(project_id, start_date, end_date, platform, product_filter)
      ActiveRecord::Base.connection.exec_query(sql).to_a
    end
  end

  def self.product_totals_sql(project_id, start_date, end_date, platform, product_filter)
    conn = ActiveRecord::Base.connection
    pid = conn.quote(Integer(project_id))
    from = conn.quote(start_date.to_date.beginning_of_day)
    to = conn.quote(end_date.to_date.end_of_day)
    platforms = Array(platform).map(&:to_s).reject(&:empty?)
    plat_sql = platforms.any? ? "AND pe.revenue_platform IN (#{platforms.map { |p| conn.quote(p) }.join(', ')})" : ""
    prod_sql = if product_filter.present?
                 sanitized = product_filter.gsub("%", '\%').gsub("_", '\_')
                 "AND pe.product_id ILIKE #{conn.quote("%#{sanitized}%")}"
               else
                 ""
               end
    buy_family = "('#{Grovs::Purchases::EVENT_BUY}', '#{Grovs::Purchases::EVENT_REFUND_REVERSED}')"

    <<~SQL
      WITH firsts AS (
          SELECT DISTINCT ON (device_id, product_id) device_id, product_id, id AS first_id
          FROM purchase_events
          WHERE project_id = #{pid} AND processed
            AND event_type IN #{buy_family} AND device_id IS NOT NULL
          ORDER BY device_id, product_id, date ASC, id ASC
        ),
        range_rows AS (
          SELECT pe.*, f.first_id
          FROM purchase_events pe
          LEFT JOIN firsts f ON f.device_id = pe.device_id AND f.product_id = pe.product_id
          WHERE pe.project_id = #{pid} AND pe.processed
            AND pe.date BETWEEN #{from} AND #{to}
            AND pe.product_id IS NOT NULL AND pe.product_id != ''
            #{plat_sql} #{prod_sql}
        ),
        alltime AS (
          SELECT product_id,
                 COALESCE(SUM(#{REVENUE_DELTA_SQL}) FILTER (WHERE device_id IS NOT NULL), 0) AS device_revenue,
                 COUNT(DISTINCT device_id) FILTER (
                   WHERE event_type IN #{buy_family} AND device_id IS NOT NULL
                 ) AS purchasing_devices
          FROM purchase_events pe
          WHERE pe.project_id = #{pid} AND pe.processed #{plat_sql}
          GROUP BY product_id
        )
        SELECT
          r.project_id,
          r.product_id,
          to_json(ARRAY_AGG(DISTINCT r.revenue_platform) FILTER (
            WHERE r.revenue_platform IS NOT NULL
              AND (#{UNITS_SOLD_SQL} > 0 OR #{CANCELLATIONS_SQL} > 0 OR #{REVENUE_DELTA_SQL} != 0)
          )) AS platforms,
          COALESCE(SUM(#{UNITS_SOLD_SQL}), 0) AS units_sold,
          COUNT(*) FILTER (WHERE r.event_type IN #{buy_family} AND r.id = r.first_id) AS first_time_purchases,
          COUNT(*) FILTER (WHERE r.event_type IN #{buy_family} AND r.device_id IS NOT NULL
                           AND r.first_id IS NOT NULL AND r.id != r.first_id) AS repeat_purchases,
          COALESCE(SUM(#{CANCELLATIONS_SQL}), 0) AS cancellations,
          COALESCE(SUM(#{REVENUE_DELTA_SQL}), 0)::bigint AS total_revenue_usd_cents,
          COUNT(DISTINCT r.device_id) FILTER (
            WHERE r.event_type IN #{buy_family} AND r.device_id IS NOT NULL
          ) AS unique_purchasers,
          MAX(CASE WHEN a.purchasing_devices > 0
              THEN a.device_revenue::float / a.purchasing_devices ELSE 0.0 END) AS ltv_usd_cents
        FROM range_rows r
        LEFT JOIN alltime a ON a.product_id = r.product_id
        GROUP BY r.project_id, r.product_id
    SQL
  end
  private_class_method :product_totals_sql

  def self.base(project_id, start_date, end_date, platform)
    rel = PurchaseEvent.where(project_id: project_id, processed: true)
                       .where(date: start_date.to_date.beginning_of_day..end_date.to_date.end_of_day)
    rel = rel.where(revenue_platform: platform) if platform.present?
    rel
  end
  private_class_method :base

  def self.revenue_map(grouped_rel)
    grouped_rel.sum(Arel.sql(REVENUE_DELTA_SQL)).transform_values(&:to_i)
  end
  private_class_method :revenue_map

  # warm_fallback: the caller's fallback table is one this flag never gates, so nil stays useful.
  def self.guarded(method, warm_fallback: false)
    yield
  rescue StandardError => e
    log_failure(method, e)
    raise RevenueLedger::Unavailable, method.to_s unless warm_fallback || RevenueLedger.stat_fallback_allowed?

    nil
  end
  private_class_method :guarded

  def self.log_failure(method, error)
    Rails.logger.error("RevenueLedgerQuery##{method}: query failed — #{error.class}: #{error.message}")
  end
  private_class_method :log_failure
end
