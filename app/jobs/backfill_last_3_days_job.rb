class BackfillLast3DaysJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  def perform
    start_date = Date.today - 2
    end_date = Date.today

    Rails.logger.info "Running scheduled backfill from #{start_date} to #{end_date}"
    DailyProjectMetricsBackfillService.call(start_date: start_date, end_date: end_date)
    Rails.logger.info "Backfill complete!"

    PrecomputeEnterpriseMausJob.perform_async
  end
end