class SubscriptionStateService
  def self.upsert(event)
    return unless event.original_transaction_id.present? && event.project_id.present?

    ActiveRecord::Base.with_connection do |conn|
      now = conn.quote(Time.current)

      sql = <<~SQL
        INSERT INTO subscription_states
          (project_id, original_transaction_id, device_id, link_id, product_id,
           latest_transaction_id, purchase_type, created_at, updated_at)
        VALUES
          (#{conn.quote(event.project_id)}, #{conn.quote(event.original_transaction_id)},
           #{conn.quote(event.device_id)}, #{conn.quote(event.link_id)},
           #{conn.quote(event.product_id)}, #{conn.quote(event.transaction_id)},
           #{conn.quote(event.purchase_type)}, #{now}, #{now})
        ON CONFLICT (project_id, original_transaction_id) DO UPDATE SET
          product_id = COALESCE(EXCLUDED.product_id, subscription_states.product_id),
          latest_transaction_id = EXCLUDED.latest_transaction_id,
          purchase_type = COALESCE(EXCLUDED.purchase_type, subscription_states.purchase_type),
          device_id = COALESCE(EXCLUDED.device_id, subscription_states.device_id),
          link_id = COALESCE(EXCLUDED.link_id, subscription_states.link_id),
          updated_at = #{now}
      SQL

      conn.execute(sql)
    end
  rescue StandardError => e
    Rails.logger.warn "Failed to upsert subscription_state for event #{event.id}: #{e.message}"
    raise
  end
end
