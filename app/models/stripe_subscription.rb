class StripeSubscription < ApplicationRecord
  belongs_to :instance
  belongs_to :stripe_payment_intent

  validates :subscription_id, presence: true
  validates :status, presence: true
  validates :customer_id, presence: true

  # Fires on create too (active nil -> true): the first row is the subscription starting, deliberately.
  after_save :audit_state_change, if: -> { saved_change_to_active? || saved_change_to_status? }

  private

  def audit_state_change
    Audit.record(instance_id: instance_id, action: "subscription.changed",
                      actor: Current.actor || AuditActor.system("StripeService"),
                      target: Audit.target_for(self).merge("subscription_id" => subscription_id),
                      changes: Audit.diff(self).transform_values { |h| h.slice("active", "status") })
  end
end
