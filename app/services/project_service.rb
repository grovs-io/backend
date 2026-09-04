class ProjectService

  # Structural boot gate: proves the MAU chain is CH-wired in THIS build (checked by Clickhouse.validate_primary_billing_wiring!).
  MAU_SOURCE = :clickhouse

  # Cache-TTL policy only: just-closed months keep the short TTL so late flushes/merges land before the 30-day freeze.
  REBUILD_GRACE_DAYS = 3

  # Callers must skip their pass (no quota mutation, no Stripe push) — never fall back to empty PG.
  class MauReadUnavailable < StandardError; end

  # Merge fold job busts cached months so a pre-merge count can't stay billable for 30 days.
  def self.bust_mau_cache(project_id, partitions)
    months = Array(partitions).compact
    return if months.empty?

    instance_id = Project.find_by(id: project_id)&.instance_id
    return unless instance_id

    months.each do |partition|
      month = "#{partition.to_s[0, 4]}-#{partition.to_s[4, 2]}"
      Rails.cache.delete("mau:#{instance_id}:#{month}")
      Rails.cache.delete("mau:ch:#{instance_id}:#{month}")
    end
  rescue StandardError => e
    Rails.logger.warn("ProjectService.bust_mau_cache failed for project #{project_id}: #{e.message}")
  end

  def initialize
  end

  def current_mau(instance)
    current_month = Date.today.month
    current_year = Date.today.year

    compute_mau(instance, current_month, current_year)
  end

  def last_month_mau(instance)
    previous_month = Date.today.prev_month.month
    previous_year = Date.today.prev_month.year

    compute_mau(instance, previous_month, previous_year)
  end

  def compute_mau(instance, month, year)
    start_date = Date.new(year, month, 1).beginning_of_day
    end_date = start_date.end_of_month.end_of_day

    compute_mau_for_dates(instance, start_date, end_date)
  end

  # fresh_unsettled_months: Stripe pushes must not read a stale unsettled-month cache (primary mode only).
  def compute_maus_per_month_total(instance, start_date, end_date, fresh_unsettled_months: false)
    return 0 if instance.nil? || instance.test.nil? || instance.production.nil?

    total_maus = 0
    today = Date.current
    primary = Clickhouse.primary?
    current_month_start = start_date.to_date.beginning_of_month
    end_date_d = end_date.to_date

    while current_month_start <= end_date_d
      current_month_end = [current_month_start.end_of_month, end_date_d].min
      completed = current_month_end < today.beginning_of_month
      settled = completed && (!primary || current_month_end < (today - REBUILD_GRACE_DAYS).beginning_of_month)
      # Separate CH namespace so a mode flip never serves values computed from the other store.
      cache_key = "#{primary ? 'mau:ch' : 'mau'}:#{instance.id}:#{current_month_start.strftime('%Y-%m')}"

      bust = fresh_unsettled_months && !settled && primary
      cached = bust ? nil : Rails.cache.read(cache_key)
      if cached
        total_maus += cached
      else
        count = compute_mau_for_dates(instance, current_month_start, current_month_end)
        ttl = settled ? 30.days : 10.minutes
        Rails.cache.write(cache_key, count, expires_in: ttl)
        total_maus += count
      end

      current_month_start = (current_month_start + 1.month).beginning_of_month
    end

    total_maus
  end

  private

  def compute_mau_for_dates(instance, start_date, end_date)
    if instance.nil? || instance.test.nil? || instance.production.nil?
      return 0
    end

    project_ids = [instance.test.id, instance.production.id]

    return clickhouse_mau(project_ids, start_date, end_date) if Clickhouse.primary?

    VisitorDailyStatistic
        .where(project_id: project_ids, event_date: start_date..end_date)
        .select(:visitor_id)
        .distinct
        .count
  end

  # Every month reads exact (FINAL + identity map at read time) — never the rebuild-fed rollup, so billing can't depend on rollup repair.
  def clickhouse_mau(project_ids, start_date, end_date)
    assert_no_spill_backlog!(project_ids, start_date, end_date)

    count = ClickhouseReadService.billing_active_visitors_exact(
      project_ids, start_date: start_date, end_date: end_date
    )

    if count.nil?
      fail_mau!("ClickHouse MAU read failed for projects #{project_ids.inspect} " \
                "(#{start_date.to_date}..#{end_date.to_date})")
    end

    count
  end

  # Drainable spill rows would make the exact read under-count — degrade until the drain lands them.
  def assert_no_spill_backlog!(project_ids, start_date, end_date)
    window = start_date.to_date.beginning_of_day..end_date.to_date.end_of_day
    in_window = ClickhouseEventSpill.where(project_id: project_ids, event_created_at: window)

    # Poison rows never drain — surface for manual review, never block billing forever.
    exhausted = in_window.where("attempts >= ?", ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS).count
    if exhausted.positive?
      Grovs::Metrics.increment("clickhouse.spill.exhausted_in_billing_window", by: exhausted)
      Rails.logger.warn(
        "clickhouse.spill.exhausted_in_billing_window count=#{exhausted} projects=#{project_ids.inspect} " \
        "— billing proceeds WITHOUT these events; review last_error, then replay (reset attempts) or delete"
      )
    end

    return unless in_window.where("attempts < ?", ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS).exists?

    fail_mau!("spill backlog pending for projects #{project_ids.inspect} — MAU would under-count")
  end

  def fail_mau!(message)
    Grovs::Metrics.increment("clickhouse.mau.read_failed")
    raise MauReadUnavailable, message
  end

end
