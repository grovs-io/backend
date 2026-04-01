class RevenueMetricsQuery
  def initialize(project_id:, start_date:, end_date:, product:, platform: nil, sort_by: nil, ascendent: true)
    @project_id = project_id
    @start_date = start_date
    @end_date = end_date
    @product = product
    @platform = platform
    @sort_by = sort_by.presence_in(allowed_sort_fields) || 'product_id'
    @asc = ascendent ? 'ASC' : 'DESC'
  end

  def with_arpu(page: 1, per_page: 20)
    data = call(page: page, per_page: per_page)

    total_visitors_query = VisitorDailyStatistic.where(
      project_id: @project_id,
      event_date: @start_date..@end_date
    )

    if @platform.present?
      total_visitors_query = total_visitors_query.where(platform: @platform)
    end

    total_visitors = total_visitors_query.distinct.count(:visitor_id)

    data.each do |row|
      revenue = row["total_revenue_usd_cents"].to_f
      row["arpu_usd_cents"] = total_visitors > 0 ? (revenue / total_visitors).round(2) : 0.0
      paying_users = row["unique_purchasers"].to_i
      row["arppu_usd_cents"] = paying_users > 0 ? (revenue / paying_users).round(2) : 0.0
    end

    data
  end

  def call(page: 1, per_page: 20)
    ActiveRecord::Base.with_connection do |conn|
      return Kaminari.paginate_array([]) unless conn.table_exists?(:in_app_product_daily_statistics)

      sql = <<~SQL
        SELECT
          iap.project_id,
          iap.product_id,
          to_json(ARRAY_AGG(DISTINCT s.platform) FILTER (WHERE s.purchase_events > 0 OR s.canceled_events > 0 OR s.revenue != 0)) AS platforms,
          COALESCE(SUM(s.purchase_events), 0) AS units_sold,
          COALESCE(SUM(s.first_time_purchases), 0) AS first_time_purchases,
          COALESCE(SUM(s.repeat_purchases), 0) AS repeat_purchases,
          COALESCE(SUM(s.canceled_events), 0) AS cancellations,
          COALESCE(SUM(s.revenue), 0)::bigint AS total_revenue_usd_cents,
          (SELECT COUNT(DISTINCT pe.device_id)
           FROM purchase_events pe
           #{unique_purchasers_device_join_sql}
           WHERE pe.project_id = iap.project_id
             AND pe.product_id = iap.product_id
             AND pe.event_type = 'buy'
             AND pe.device_id IS NOT NULL
             AND pe.date >= #{conn.quote(@start_date)} AND pe.date < #{conn.quote(@end_date + 1)}
             #{unique_purchasers_platform_sql}
          ) AS unique_purchasers,
          (SELECT CASE WHEN SUM(iap3.unique_purchasing_devices) > 0
             THEN (SELECT COALESCE(SUM(s2.device_revenue), 0)
                   FROM in_app_product_daily_statistics s2
                   JOIN in_app_products iap2 ON iap2.id = s2.in_app_product_id
                   WHERE iap2.project_id = iap.project_id
                     AND iap2.product_id = iap.product_id
                     #{ltv_platform_filter_sql})::FLOAT
                  / SUM(iap3.unique_purchasing_devices)
             ELSE 0.0 END
           FROM in_app_products iap3
           WHERE iap3.project_id = iap.project_id
             AND iap3.product_id = iap.product_id
          ) AS ltv_usd_cents
        FROM in_app_product_daily_statistics s
        JOIN in_app_products iap ON iap.id = s.in_app_product_id
        WHERE iap.project_id = #{conn.quote(@project_id)}
          AND s.event_date BETWEEN #{conn.quote(@start_date)} AND #{conn.quote(@end_date)}
          #{platform_filter_sql}
          #{product_filter_sql}
        GROUP BY iap.project_id, iap.product_id
        ORDER BY #{@sort_by} #{@asc}
        LIMIT #{per_page.to_i} OFFSET #{(page.to_i - 1) * per_page.to_i}
      SQL

      results = conn.exec_query(sql).to_a

      total = count_products(conn)
      offset = (page.to_i - 1) * per_page.to_i
      Kaminari.paginate_array(results, total_count: total, limit: per_page.to_i, offset: offset)
    end
  end

  private

  def count_products(conn)
    sql = <<~SQL
      SELECT COUNT(DISTINCT iap.product_id)
      FROM in_app_product_daily_statistics s
      JOIN in_app_products iap ON iap.id = s.in_app_product_id
      WHERE iap.project_id = #{conn.quote(@project_id)}
        AND s.event_date BETWEEN #{conn.quote(@start_date)} AND #{conn.quote(@end_date)}
        #{platform_filter_sql}
        #{product_filter_sql}
    SQL
    conn.exec_query(sql).rows.first&.first.to_i
  end

  def platform_filter_sql
    return "" if @platform.blank?
    "AND s.platform IN (#{quoted_platforms})"
  end

  def unique_purchasers_device_join_sql
    return "" if @platform.blank?
    "JOIN devices d ON d.id = pe.device_id"
  end

  def unique_purchasers_platform_sql
    return "" if @platform.blank?
    "AND d.platform IN (#{quoted_platforms})"
  end

  def ltv_platform_filter_sql
    return "" if @platform.blank?
    "AND s2.platform IN (#{quoted_platforms})"
  end

  def quoted_platforms
    Array(@platform).map { |p| quote(p) }.join(", ")
  end

  def product_filter_sql
    return "" if @product.blank?
    sanitized = @product.gsub('%', '\%').gsub('_', '\_')
    "AND iap.product_id ILIKE #{quote("%#{sanitized}%")}"
  end

  def quote(val)
    ActiveRecord::Base.with_connection { |conn| conn.quote(val) }
  end

  def allowed_sort_fields
    %w[
      product_id
      project_id
      units_sold
      first_time_purchases
      repeat_purchases
      cancellations
      total_revenue_usd_cents
    ]
  end
end
