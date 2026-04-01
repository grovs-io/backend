class SendMessagesJob
  include Sidekiq::Job

  def perform(notification_id)

    
    handle_notification(notification_id)
  rescue StandardError => e
    # Log and re-raise so Sidekiq retries (25 attempts, exponential backoff).
    # Previously errors were swallowed silently, losing failed sends.
    Rails.logger.error("SendMessagesJob error for notification #{notification_id}: #{e.message}")
    raise
    
  end

  # Private methods
  private

  def handle_notification(notification_id)
    notification = Notification.find_by(id: notification_id)
    unless notification
      return
    end

    Rails.logger.debug("Found notification #{notification}")

    # Create the messages
    NotificationMessageService.create_notification_messages_for_existing_users(notification)
  end

end