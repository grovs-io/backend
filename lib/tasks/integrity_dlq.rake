namespace :events do
  desc "Replay parked integrity-DLQ payloads back to events:pending (fix the root cause first)"
  task drain_integrity_dlq: :environment do
    moved = BatchEventProcessorJob.drain_integrity_dlq!
    puts "Moved #{moved} payload(s) from #{BatchEventProcessorJob::INTEGRITY_DLQ_KEY} to #{BatchEventProcessorJob::REDIS_KEY}"
  end
end
