class PrecomputeEnterpriseMausJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  def perform
    EnterpriseSubscription.where(active: true).includes(:instance).find_each do |es|
      instance = es.instance
      next unless instance

      # Raise statement_timeout for background MAU computation —
      # individual month queries are small but can be slow on large tables.
      ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '120s'")
      total_maus = ProjectService.new.compute_maus_per_month_total(instance, es.start_date, Time.current)
      Rails.cache.write("enterprise_mau:#{instance.id}", total_maus, expires_in: 30.minutes)
    end
  rescue StandardError => e
    Rails.logger.error("Enterprise MAU precompute failed: #{e.class} - #{e.message}")
  end
end
