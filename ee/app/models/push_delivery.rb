class PushDelivery < ApplicationRecord
  STATUSES = %w[pending claimed queued delivered failed no_channel not_found cancelled held waiting].freeze
  DEAD_TOKEN_ERRORS = %w[Unregistered BadDeviceToken].freeze
  FCM_UNREGISTERED = "Client was not registered".freeze
  APNS_REASON = /\A[A-Z][A-Za-z]+\z/

  belongs_to :push_campaign
  belongs_to :visitor, optional: true

  validates :status, inclusion: { in: STATUSES }

  # APNs 404 is BadPath; rpush wraps FCM's 404 wording in a longer "received error 404 (…)".
  def self.dead_token_error?(code, description)
    DEAD_TOKEN_ERRORS.include?(description.to_s) || (code.to_i == 404 && description.to_s.include?(FCM_UNREGISTERED))
  end

  # A sandbox app's BadDeviceToken is usually a production token, which must survive the failure.
  def self.token_kept_app_ids(description, app_ids)
    return Set.new unless description.to_s == "BadDeviceToken"

    Rpush::Client::ActiveRecord::App.where(id: app_ids.uniq, environment: %w[development sandbox]).pluck(:id).to_set
  end

  Settled = Struct.new(:push_campaign_id, :device_id, :rpush_notification_id, :variant)

  def self.record_delivered!(rpush_id) = record_delivered_batch!([rpush_id]).first

  def self.record_failed!(rpush_id, code, description) = record_failed_batch!([rpush_id], code, description).first

  # One UPDATE and one counter bump per campaign for a whole rpush batch; only queued rows move.
  def self.record_delivered_batch!(rpush_ids)
    settle_all(rpush_ids, status: "delivered") { |campaign_id, n| PushCampaign.bump!(campaign_id, delivered: n) }
  end

  # APNs reasons are a bounded CamelCase set worth keying on; FCM sentences fall back to the code.
  def self.record_failed_batch!(rpush_ids, code, description)
    error = (description.to_s.match?(APNS_REASON) ? description.to_s : code.to_s).first(64)
    settle_all(rpush_ids, status: "failed", error: error) do |campaign_id, n|
      PushCampaign.bump!(campaign_id, failed: n, errors: { error => n })
    end
  end

  def self.record_open!(campaign, visitor)
    transaction do
      now = Time.current
      n = where(push_campaign_id: campaign.id, visitor_id: visitor.id, opened_at: nil).update_all(opened_at: now, updated_at: now)
      next false if n.zero?

      PushCampaign.bump!(campaign.id, opened: 1)
      true
    end
  end

  # Settles queued rows rpush already settled; rows it is still retrying can't block them.
  def self.reconcile_queued!(older_than:, limit: 1000)
    outcomes = where(status: "queued").where(updated_at: ...older_than)
                                      .joins("JOIN rpush_notifications n ON n.id = push_deliveries.rpush_notification_id AND (n.delivered OR n.failed)")
                                      .order(:updated_at).limit(limit)
                                      .pluck("n.id", "n.delivered", "n.error_code", "n.error_description", "n.device_token", "n.app_id")
    return 0 if outcomes.empty?

    delivered, failed = outcomes.partition { |_, ok| ok }
    settled = record_delivered_batch!(delivered.map(&:first)).size
    failed.group_by { |_, _, code, desc| [code, desc] }.each do |(code, desc), group|
      settled_rows = record_failed_batch!(group.map(&:first), code, desc)
      settled += settled_rows.size
      next unless dead_token_error?(code, desc)

      kept = token_kept_app_ids(desc, group.map(&:last))
      tokens = group.to_h { |id, *, token, app_id| [id, (token unless kept.include?(app_id))] }
      settled_rows.each { |row| PushOutcomes.dead_device(row.device_id, tokens[row.rpush_notification_id]) }
    end
    settled
  end

  # Stale rpush rows of cancelled campaigns are dropped instead of going back to the queue.
  def self.withdraw_cancelled!(rpush_ids)
    rows = joins(:push_campaign).where(rpush_notification_id: rpush_ids, status: "queued", push_campaigns: { status: "cancelled" })
                                .pluck(:id, :push_campaign_id, :rpush_notification_id)
    return 0 if rows.empty?

    transaction do
      Rpush::Notification.where(id: rows.map(&:last)).delete_all
      where(id: rows.map(&:first)).update_all(status: "cancelled", updated_at: Time.current)
      rows.group_by(&:second).sort.each { |campaign_id, group| PushCampaign.bump!(campaign_id, cancelled: group.size, queued: -group.size) }
    end
    rows.size
  end

  def self.settle_all(rpush_ids, status:, error: nil)
    return [] if rpush_ids.empty?

    sql = sanitize_sql_array([<<~SQL, status, error, rpush_ids])
      UPDATE push_deliveries SET status = ?, error = COALESCE(?, error), updated_at = NOW()
      WHERE rpush_notification_id IN (?) AND status = 'queued'
      RETURNING push_campaign_id, device_id, rpush_notification_id, variant
    SQL
    transaction do
      rows = with_connection { |c| c.exec_query(sql) }.rows.map { |r| Settled.new(*r) }
      rows.group_by(&:push_campaign_id).sort.each { |campaign_id, group| yield campaign_id, group.size }
      rows
    end
  end
  private_class_method :settle_all
end
