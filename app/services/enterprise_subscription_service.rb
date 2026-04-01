class EnterpriseSubscriptionService
  # Returns EnterpriseSubscription.
  # Raises if instance already has active subscription or required fields missing.
  def self.create(instance_id:, start_date:, end_date:, total_maus:, active:)
    missing = []
    missing << "start_date" if start_date.blank?
    missing << "end_date" if end_date.blank?
    missing << "total_maus" if total_maus.blank?
    raise ArgumentError, "Missing required fields: #{missing.join(', ')}" if missing.any?

    instance = Instance.find_by(id: instance_id)
    raise ActiveRecord::RecordNotFound, "Instance not found" unless instance

    existing = EnterpriseSubscription.find_by(instance_id: instance.id, active: true)
    raise ArgumentError, "Instance already has an active subscription" if existing

    EnterpriseSubscription.create!(
      start_date: start_date,
      end_date: end_date,
      total_maus: total_maus,
      active: active,
      instance_id: instance.id
    )
  end

  # Returns EnterpriseSubscription.
  # Raises RecordNotFound if subscription doesn't exist.
  def self.update(id:, attrs:)
    subscription = EnterpriseSubscription.find_by(id: id)
    raise ActiveRecord::RecordNotFound, "Enterprise Subscription not found" unless subscription

    subscription.update!(attrs)
    subscription
  end
end
