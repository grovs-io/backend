class AddRevenueCollectionEnabledToInstances < ActiveRecord::Migration[7.0]
  def change
    unless column_exists?(:instances, :revenue_collection_enabled)
      add_column :instances, :revenue_collection_enabled, :boolean, default: false, null: false
    end
  end
end
