# app/jobs/backfill_project_daily_active_users_job.rb
class BackfillProjectDailyActiveUsersJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  def perform
    (Date.today - 1..Date.today).each do |date|
      ProjectDailyActiveUsersGenerator.call(date)
    end
  end
end