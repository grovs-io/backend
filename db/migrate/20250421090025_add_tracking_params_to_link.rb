class AddTrackingParamsToLink < ActiveRecord::Migration[7.0]
  def change
    add_column :links, :tracking_campaign, :string, null: true
    add_column :links, :tracking_source, :string, null: true
    add_column :links, :tracking_medium, :string, null: true
  end
end
