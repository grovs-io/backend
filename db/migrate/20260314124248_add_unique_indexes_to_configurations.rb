class AddUniqueIndexesToConfigurations < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    remove_index :android_configurations, :application_id, if_exists: true
    add_index :android_configurations, :application_id, unique: true, algorithm: :concurrently

    remove_index :desktop_configurations, :application_id, if_exists: true
    add_index :desktop_configurations, :application_id, unique: true, algorithm: :concurrently

    remove_index :ios_configurations, :application_id, if_exists: true
    add_index :ios_configurations, :application_id, unique: true, algorithm: :concurrently

    remove_index :web_configurations, :application_id, if_exists: true
    add_index :web_configurations, :application_id, unique: true, algorithm: :concurrently
  end
end
