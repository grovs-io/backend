class AddQuotaEmailTrackingToInstances < ActiveRecord::Migration[7.0]
  def change
    add_column :instances, :last_quota_warning_sent_at, :datetime
    add_column :instances, :last_quota_exceeded_sent_at, :datetime
  end
end
