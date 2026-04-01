module PurchaseAttributionService
  # Returns { device_id: ..., link_id: ... } from the most recent previous
  # purchase with the same original_transaction_id.
  # Queries subscription_states first (fast, cold-storage-safe), falls back
  # to purchase_events for graceful migration.
  def find_attribution_from_previous_purchase(original_transaction_id, project)
    # Try subscription_states first (sole source of truth once fully populated)
    state = SubscriptionState.find_by(
      original_transaction_id: original_transaction_id,
      project_id: project.id
    )
    if state && (state.device_id.present? || state.link_id.present?)
      return { device_id: state.device_id, link_id: state.link_id }
    end

    # Fall back to purchase_events (graceful migration period)
    row = PurchaseEvent.where(
      original_transaction_id: original_transaction_id,
      project_id: project.id
    ).where("device_id IS NOT NULL OR link_id IS NOT NULL")
     .order(date: :desc)
     .pick(:device_id, :link_id)

    { device_id: row&.first, link_id: row&.last }
  end

  def cached_google_json_key(instance)
    auth_file = instance&.android_application&.configuration&.android_server_api_key&.file
    return nil unless auth_file&.attached?

    cache_key = "google_iap_key:#{instance.id}:#{auth_file.blob.checksum}"
    cached = Rails.cache.read(cache_key)
    return cached if cached

    json_key = auth_file.download
    Rails.cache.write(cache_key, json_key, expires_in: 24.hours)
    json_key
  end

  module_function :find_attribution_from_previous_purchase, :cached_google_json_key
end
