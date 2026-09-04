class PrecomputeEnterpriseMausJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  def perform
    EnterpriseSubscription.where(active: true).includes(:instance).find_each do |es|
      instance = es.instance
      next unless instance

      total_maus = ProjectService.new.compute_maus_per_month_total(instance, es.start_date, Time.current)
      # Outlives the 30-min cron so a web request never falls through to computing this itself.
      Rails.cache.write("enterprise_mau:#{instance.id}", total_maus, expires_in: 45.minutes)
    rescue ProjectService::MauReadUnavailable => e
      # Keep the loop going; the stale cached value beats aborting later enterprises.
      Rails.logger.error("clickhouse.mau.read_failed instance=#{instance.id} — enterprise MAU not refreshed: #{e.message}")
    end
  rescue StandardError => e
    Rails.logger.error("Enterprise MAU precompute failed: #{e.class} - #{e.message}")
  end
end
