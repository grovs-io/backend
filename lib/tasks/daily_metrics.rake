namespace :daily_metrics do
  desc "Backfill DailyProjectMetrics from 2010-01-01 to today"
  task backfill: :environment do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.today

    puts "🛠 Starting backfill from #{start_date} to #{end_date}..."

    DailyProjectMetricsBackfillService.call(start_date: start_date, end_date: end_date)

    puts "✅ Backfill complete!"
  end

  task backfill_daus: :environment do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.today

    puts "🛠 Backfilling project daily active users from #{start_date} to #{end_date}..."

    (start_date..end_date).each do |date|
      puts "📅 Processing #{date}..."
      ProjectDailyActiveUsersGenerator.call(date)
    end

    puts "✅ Backfill complete!"
  end
end