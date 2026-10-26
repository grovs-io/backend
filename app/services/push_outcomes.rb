# rpush batch outcomes land here; the per-campaign bookkeeping in ee/ is skipped without it.
module PushOutcomes
  module_function

  # Runs in the daemon's delivery thread per batch; the row gives the device, never scan by token.
  def delivered_batch(notifications)
    return if notifications.empty? || !defined?(PushDelivery)

    PushDelivery.record_delivered_batch!(notifications.map(&:id))
  rescue StandardError => e
    Rails.logger.error("push_outcomes.delivered.failed #{e.class}: #{e.message}")
  end

  def failed_batch(notifications, code, description)
    return if notifications.empty? || !defined?(PushDelivery)

    record_failed(notifications, code, description)
  rescue StandardError => e
    Rails.logger.error("push_outcomes.failed.failed #{e.class}: #{e.message}")
  end

  def record_failed(notifications, code, description)
    rows = PushDelivery.record_failed_batch!(notifications.map(&:id), code, description)
    return unless PushDelivery.dead_token_error?(code, description)

    kept = PushDelivery.token_kept_app_ids(description, notifications.map(&:app_id))
    tokens = notifications.to_h { |n| [n.id, (n.device_token unless kept.include?(n.app_id))] }
    rows.each { |row| dead_device(row.device_id, tokens[row.rpush_notification_id]) }
  end

  # Raises, so the caller's delete rolls back instead of leaving queued rows with no rpush row.
  def abandoned(rpush_ids)
    return if rpush_ids.empty? || !defined?(PushDelivery)

    PushDelivery.record_failed_batch!(rpush_ids, "app_removed", nil)
  end

  # Raises on failure, so the caller never releases a cancelled campaign's pushes back to the queue.
  def withdraw_cancelled(rpush_ids)
    return 0 if rpush_ids.empty? || !defined?(PushDelivery)

    PushDelivery.withdraw_cancelled!(rpush_ids)
  end

  # Settles deliveries whose rpush rows are about to go; raises, so unkept outcomes aren't deleted.
  def settle(notifications)
    return unless defined?(PushDelivery)

    delivered, failed = notifications.partition(&:delivered)
    PushDelivery.record_delivered_batch!(delivered.map(&:id)) if delivered.any?
    failed.group_by { |n| [n.error_code, n.error_description] }.each { |(code, desc), group| record_failed(group, code, desc) }
  end

  def delivered(notification) = notification && delivered_batch([notification])
  def failed(notification)
    notification && failed_batch([notification], notification.error_code, notification.error_description)
  end

  # Only the token that failed is cleared: a device that re-registered meanwhile keeps its fresh one.
  def dead_device(device_id, token)
    return if token.blank?

    device = Device.find_by(id: device_id, push_token: token)
    return if device.nil?

    device.update_columns(push_token: nil, updated_at: Time.current)
    keys = device.cache_keys_to_clear
    REDIS.del(*keys) if keys.present?
  rescue StandardError => e
    Rails.logger.error("push_outcomes.dead_device.failed #{e.class}: #{e.message}")
  end

  def opened(project:, visitor:, campaign_id:)
    return :unavailable unless defined?(PushDelivery)

    campaign = project.push_campaigns.find_by_hashid(campaign_id)
    return :not_found if campaign.nil?

    PushDelivery.record_open!(campaign, visitor) ? :ok : :noop
  end
end
