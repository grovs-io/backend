class AddGoogleTrackingToDomains < ActiveRecord::Migration[7.0]
  def change
    add_column :domains, :google_tracking_id, :string
  end
end
