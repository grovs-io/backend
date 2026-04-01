namespace :purchase_events do
  desc "Enqueue unprocessed purchase events for processing"
  task process_unprocessed: :environment do
    scope = PurchaseEvent.where(processed: false)
                         .where("webhook_validated = true OR store = false")

    total = scope.count
    puts "Enqueuing #{total} unprocessed purchase events"

    scope.find_each do |event|
      ProcessPurchaseEventJob.perform_async(event.id)
    end

    puts "Done — enqueued #{total} events"
  end
end
