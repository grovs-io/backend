class MailDeliveryJob < ActionMailer::MailDeliveryJob
  # The recipient was destroyed before Sidekiq drained the queue; retrying can never resolve it.
  discard_on ActiveJob::DeserializationError
end
