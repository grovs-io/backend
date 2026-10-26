module AuditTestHelper
  def entitle!(instance)
    EnterpriseSubscription.create!(instance: instance, active: true, start_date: 1.day.ago,
                                   end_date: 1.year.from_now, total_maus: 100)
  end

  def unentitle!(instance)
    EnterpriseSubscription.where(instance: instance).delete_all
    StripeSubscription.where(instance: instance).update_all(active: false)
  end
end
