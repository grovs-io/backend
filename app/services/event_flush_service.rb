class EventFlushService
  # Returns { processed:, discarded:, dates_aggregated: }
  def self.flush(aggregate_days: 1)
    key = BatchEventProcessorJob::REDIS_KEY
    # Discard events older than 5 minutes: if events have been sitting in Redis
    # this long, the batch processor was down. Stale events would produce
    # backdated statistics that have already been aggregated by
    # BackfillLast3DaysJob, causing double-counting.
    cutoff = 5.minutes.ago

    all_raw = []
    while (raw = REDIS.rpop(key))
      all_raw << raw
    end

    processed = 0
    discarded = 0

    if all_raw.any?
      recent = all_raw.select do |raw|
        payload = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end
        next false unless payload
        ts = payload["created_at"]
        parsed_ts = begin
          ts ? Time.parse(ts) : nil
        rescue ArgumentError
          Time.current
        end
        ts.nil? || parsed_ts >= cutoff
      end

      if recent.any?
        job = BatchEventProcessorJob.new
        job.jid = SecureRandom.hex(12)
        job.send(:process_batch, recent)
      end

      processed = recent.size
      discarded = all_raw.size - recent.size
    end

    days = aggregate_days.to_i.clamp(1, 7)
    dates_aggregated = []
    days.times do |i|
      date = Date.today - i
      DailyProjectMetricsGenerator.call(date)
      ProjectDailyActiveUsersGenerator.call(date)
      dates_aggregated << date.to_s
    end

    {
      processed: processed,
      discarded: discarded,
      dates_aggregated: dates_aggregated
    }
  end
end
