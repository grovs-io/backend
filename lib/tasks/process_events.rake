# lib/tasks/process_events.rake
namespace :events do
  desc "Process all historical events with visitor + link metrics (FASTEST without Parallel)"
  task process_all_fast_new: :environment do
    batch_size = 10_000
    update_batch_size = 10_000
    num_threads = 6

    total = Event.where(processed: false).count
    processed = 0
    updates_batch = []
    event_ids = []

    Rails.logger.error "🚀 Starting optimized processing of #{total} events..."
    start_time = Time.current

    Event.where(processed: false)
        .includes(:device, :link, device: :visitors)
        .find_in_batches(batch_size: batch_size) do |events|

      # Split into N chunks for threading
      chunks = events.each_slice((events.size / num_threads.to_f).ceil).to_a
      threads = []

      mutex = Mutex.new

      chunks.each do |chunk|
        threads << Thread.new do
          local_updates = []
          local_event_ids = []

          chunk.each do |event|
            updates = EventStatDispatchService.call_normal_event_bulk(event)
            if updates
              local_updates << updates
              local_event_ids << event.id
            end
          end

          # Safely merge into shared batch
          mutex.synchronize do
            updates_batch.concat(local_updates)
            event_ids.concat(local_event_ids)

            if updates_batch.size >= update_batch_size
              EventStatDispatchService.bulk_process_updates(updates_batch)
              Event.where(id: event_ids).update_all(processed: true)
              updates_batch.clear
              event_ids.clear
            end
          end
        end
      end

      # Wait for threads to finish
      threads.each(&:join)

      processed += events.size
      elapsed = Time.current - start_time
      rate = processed / elapsed
      eta = (total - processed) / rate

      Rails.logger.error(
        "\n\n Processed #{processed}/#{total} (#{(processed.to_f / total * 100).round(1)}%) " \
        "- Rate: #{rate.round(0)} events/sec - ETA: #{eta.round(0)}s"
      )
    end

    # Final flush
    unless updates_batch.empty?
      EventStatDispatchService.bulk_process_updates(updates_batch)
      Event.where(id: event_ids).update_all(processed: true)
    end

    elapsed = Time.current - start_time
    Rails.logger.error "✅ Finished processing #{processed} events in #{elapsed.round(2)}s (#{(processed / elapsed).round(0)} events/sec)"
  end
  
end