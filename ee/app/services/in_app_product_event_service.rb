class InAppProductEventService
  # Upsert a purchase event's metrics into in_app_product_daily_statistics.
  #
  # Finds or creates the InAppProduct, then increments the appropriate
  # counters (revenue, purchase_events, canceled_events, first_time_purchases,
  # repeat_purchases, device_revenue) in a single upsert keyed on
  # (in_app_product_id, event_date, platform).
  def self.record_purchase(event, platform: nil, event_date: nil)
    return unless event.product_id.present? && event.project_id.present?

    platform   ||= event.device&.platform_for_metrics || Grovs::Platforms::WEB
    event_date ||= (event.date || event.created_at)&.to_date || Date.current
    in_app_product = find_or_create_product(event.project_id, event.product_id, platform)

    revenue_delta    = event.revenue_delta || 0
    is_first_time    = event.buy? && first_time_purchase?(event)
    is_repeat        = event.buy? && !is_first_time && event.device_id.present?
    has_device       = event.device_id.present?

    # Increment unique_purchasing_devices on the product for first-time device purchases
    if is_first_time && has_device
      InAppProduct.where(id: in_app_product.id)
                  .update_all("unique_purchasing_devices = unique_purchasing_devices + 1")
    end

    upsert_stats(
      in_app_product_id: in_app_product.id,
      project_id:        event.project_id,
      event_date:        event_date,
      platform:          platform,
      revenue:           revenue_delta,
      purchase_events:   event.buy? ? event.quantity : 0,
      canceled_events:   event.cancellation? ? event.quantity : 0,
      first_time_purchases: is_first_time ? 1 : 0,
      repeat_purchases:  is_repeat ? 1 : 0,
      device_revenue:    has_device ? revenue_delta : 0
    )

    is_first_time
  end

  # Apply only a revenue correction (no event-count changes).
  # Used when webhook delivers authoritative pricing after initial processing.
  def self.apply_revenue_correction(event, platform:, event_date:, correction:)
    return unless event.product_id.present? && event.project_id.present?

    in_app_product = find_or_create_product(event.project_id, event.product_id, platform)
    has_device = event.device_id.present?

    upsert_stats(
      in_app_product_id: in_app_product.id,
      project_id:        event.project_id,
      event_date:        event_date,
      platform:          platform,
      revenue:           correction,
      purchase_events:   0,
      canceled_events:   0,
      first_time_purchases: 0,
      repeat_purchases:  0,
      device_revenue:    has_device ? correction : 0
    )
  end

  # Record device-specific IAP tracking when platform already matched at
  # initial processing (no metric-moving needed). Handles first-time purchase
  # detection, unique_purchasing_devices, and device_revenue that were skipped
  # because no device was present at webhook time.
  def self.record_device_attribution(event, platform:, event_date:)
    return unless event.product_id.present? && event.project_id.present? && event.device_id.present?

    in_app_product = find_or_create_product(event.project_id, event.product_id, platform)

    is_first_time = event.buy? && first_time_purchase?(event)
    revenue_delta = event.revenue_delta || 0

    if is_first_time
      InAppProduct.where(id: in_app_product.id)
                  .update_all("unique_purchasing_devices = unique_purchasing_devices + 1")
    end

    upsert_stats(
      in_app_product_id: in_app_product.id,
      project_id:        event.project_id,
      event_date:        event_date,
      platform:          platform,
      revenue:           0,
      purchase_events:   0,
      canceled_events:   0,
      first_time_purchases: is_first_time ? 1 : 0,
      repeat_purchases:  event.buy? && !is_first_time ? 1 : 0,
      device_revenue:    revenue_delta
    )
  end

  def self.find_or_create_product(project_id, product_id, platform)
    InAppProduct.find_or_create_by!(project_id: project_id, product_id: product_id, platform: platform)
  rescue ActiveRecord::RecordNotUnique
    InAppProduct.find_by!(project_id: project_id, product_id: product_id, platform: platform)
  end

  private_class_method :find_or_create_product

  def self.first_time_purchase?(event)
    return false unless event.device_id.present?

    ActiveRecord::Base.with_connection do |conn|
      sql = <<~SQL
        INSERT INTO device_product_purchases (device_id, project_id, product_id, created_at)
        VALUES (#{conn.quote(event.device_id)}, #{conn.quote(event.project_id)},
                #{conn.quote(event.product_id)}, NOW())
        ON CONFLICT (device_id, project_id, product_id) DO NOTHING
        RETURNING id
      SQL
      result = conn.execute(sql)
      result.ntuples > 0
    end
  end

  private_class_method :first_time_purchase?

  def self.upsert_stats(in_app_product_id:, project_id:, event_date:, platform:, revenue:, purchase_events:, canceled_events:, first_time_purchases:, 
                        repeat_purchases:, device_revenue:)
    ActiveRecord::Base.with_connection do |conn|
      sql = <<~SQL
        INSERT INTO in_app_product_daily_statistics
          (in_app_product_id, project_id, event_date, platform, revenue,
           purchase_events, canceled_events, first_time_purchases,
           repeat_purchases, device_revenue, created_at, updated_at)
        VALUES
          (#{conn.quote(in_app_product_id)}, #{conn.quote(project_id)}, #{conn.quote(event_date)},
           #{conn.quote(platform)}, #{revenue.to_i},
           #{purchase_events.to_i}, #{canceled_events.to_i}, #{first_time_purchases.to_i},
           #{repeat_purchases.to_i}, #{device_revenue.to_i},
           NOW(), NOW())
        ON CONFLICT (in_app_product_id, event_date, platform)
        DO UPDATE SET
          revenue = COALESCE(in_app_product_daily_statistics.revenue, 0) + #{revenue.to_i},
          purchase_events = COALESCE(in_app_product_daily_statistics.purchase_events, 0) + #{purchase_events.to_i},
          canceled_events = COALESCE(in_app_product_daily_statistics.canceled_events, 0) + #{canceled_events.to_i},
          first_time_purchases = COALESCE(in_app_product_daily_statistics.first_time_purchases, 0) + #{first_time_purchases.to_i},
          repeat_purchases = COALESCE(in_app_product_daily_statistics.repeat_purchases, 0) + #{repeat_purchases.to_i},
          device_revenue = COALESCE(in_app_product_daily_statistics.device_revenue, 0) + #{device_revenue.to_i},
          updated_at = NOW()
      SQL

      conn.execute(sql)
    end
  end

  private_class_method :upsert_stats

  # Adjust stats on the old platform row when attribution backfill moves
  # them to the real platform. Subtracts counts and optionally revenue.
  def self.upsert_stats_correction(event, platform:, event_date:, purchase_events:, canceled_events:, first_time_purchases: 0, revenue: 0)
    return unless event.product_id.present? && event.project_id.present?

    in_app_product = InAppProduct.find_by(project_id: event.project_id, product_id: event.product_id, platform: platform)
    return unless in_app_product

    upsert_stats(
      in_app_product_id: in_app_product.id,
      project_id:        event.project_id,
      event_date:        event_date,
      platform:          platform,
      revenue:           revenue,
      purchase_events:   purchase_events,
      canceled_events:   canceled_events,
      first_time_purchases: first_time_purchases,
      repeat_purchases:  0,
      device_revenue:    0
    )
  end
end
